#!/usr/bin/env python3
"""Signs a Launcher release's update manifest and publishes it to R2.

    release.py TAG COMMIT OUT --archive NAME --dmg-arm64 NAME --dmg-x86-64 NAME --notes FILE [--assemble-only] < credentials.json

OUT holds the notarized update archive and disk image that scripts/release.sh
built. This writes OUT/manifest.json, its OpenSSH signature and OUT/latest.json
(the manifest's exact text with the signature, which the Launcher verifies with
the key in devops/allowed_signers), then uploads:

1. the version folder, macos/releases/<tag>/, whose files never change: a
   published version is never overwritten;
2. after checking that every file downloads from SITE with its SHA-256,
   macos/latest.json, which the Worker serves to be revalidated on every request.

latest.json is only moved forward: rerunning an older tag leaves it alone.
Credentials come as JSON on stdin: UPDATE_SIGNING_KEY, and for publishing
R2_ENDPOINT, R2_BUCKET, R2_ACCESS_KEY_ID and R2_SECRET_ACCESS_KEY.
"""
import argparse
import datetime
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VERSION = r"(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})"
NAMESPACE = "gizlet-macos-update"
MINIMUM_MACOS = "14.0"
SITE = os.environ.get("GIZLET_SITE", "https://gizlet.io")
PREFIX = "macos"


def version_tuple(text):
    match = re.fullmatch(VERSION, text)
    if not match:
        raise ValueError(f"{text} is not MAJOR.MINOR.PATCH")
    return tuple(int(part) for part in match.groups())


def describe(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            digest.update(chunk)
    return {"path": path.name, "sha256": digest.hexdigest(), "bytes": path.stat().st_size}


def trusted_key(allowed_signers):
    """The public key line in allowed_signers: `launcher namespaces="..." ssh-ed25519 AAAA...`."""
    fields = allowed_signers.read_text().split()
    return fields[-2:]


def assemble(tag, commit, out, archive, dmgs, notes, signing_key, allowed_signers=ROOT / "devops/allowed_signers", now=None):
    version = tag[1:]
    version_tuple(version)
    expected = {"arm64": f"Gizlet-{version}-arm64.dmg", "x86_64": f"Gizlet-{version}-x86_64.dmg"}
    if dmgs != expected:
        raise ValueError(f"Expected one installer for each architecture: {expected}")
    images = {arch: describe(out / name) for arch, name in dmgs.items()}
    manifest = {
        "schema": 1,
        "version": version,
        "tag": tag,
        "commit": commit,
        "minimum_macos": MINIMUM_MACOS,
        "published_at": (now or datetime.datetime.now(datetime.timezone.utc)).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "notes": {"en": notes.strip()},
        "archive": describe(out / archive),
        "dmg": images["arm64"],
        "dmgs": images,
    }
    text = json.dumps(manifest, indent=2, ensure_ascii=False) + "\n"
    manifest_path = out / "manifest.json"
    manifest_path.write_text(text)
    with tempfile.TemporaryDirectory() as private:
        key = Path(private) / "update"
        key.touch(mode=0o600)
        key.write_text(signing_key.rstrip("\n") + "\n")
        public = subprocess.check_output(["ssh-keygen", "-y", "-f", str(key)], text=True).split()[:2]
        if public != trusted_key(allowed_signers):
            raise ValueError("UPDATE_SIGNING_KEY does not match the key in devops/allowed_signers")
        signature = manifest_path.with_name("manifest.json.sig")
        if signature.exists():
            signature.unlink()
        subprocess.run(["ssh-keygen", "-q", "-Y", "sign", "-f", str(key), "-n", NAMESPACE, str(manifest_path)], check=True)
    verify(text, signature.read_text(), allowed_signers)
    write_envelope(out, text, signature.read_text())
    return manifest


def verify(text, signature, allowed_signers):
    """Fails unless signature is the update key's signature of text."""
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "manifest.json.sig"
        path.write_text(signature)
        subprocess.run(
            ["ssh-keygen", "-q", "-Y", "verify", "-f", str(allowed_signers), "-I", "launcher", "-n", NAMESPACE, "-s", str(path)],
            input=text.encode(), check=True, stdout=subprocess.DEVNULL,
        )


def write_envelope(out, text, signature):
    envelope = {"schema": 1, "manifest": text, "signature": signature}
    (out / "latest.json").write_text(json.dumps(envelope, indent=2) + "\n")


def published_release(tag, commit, out, site=SITE, allowed_signers=ROOT / "devops/allowed_signers"):
    """The manifest an earlier run of this release published, checked and made OUT's latest.json.

    A version folder never changes, so a release cut short after uploading it
    finishes with what it published, not with this run's rebuilt files.
    """
    folder = f"{site}/assets/{PREFIX}/releases/{tag}/"
    text = fetch(folder + "manifest.json").decode()
    signature = fetch(folder + "manifest.json.sig").decode()
    verify(text, signature, allowed_signers)
    manifest = json.loads(text)
    if manifest.get("tag") != tag or manifest.get("commit") != commit:
        raise ValueError(f"{tag} is already published from another commit")
    write_envelope(out, text, signature)
    return manifest


class R2:
    """put and head on an R2 bucket through curl's AWS Signature Version 4."""

    def __init__(self, credentials):
        self.endpoint = credentials["R2_ENDPOINT"]
        self.bucket = credentials["R2_BUCKET"]
        if not re.fullmatch(r"https://[a-f0-9]{32}(?:\.(?:eu|fedramp))?\.r2\.cloudflarestorage\.com", self.endpoint):
            raise ValueError("Expected a Cloudflare R2 S3 endpoint")
        if not re.fullmatch(r"[a-z0-9][a-z0-9-]{1,61}[a-z0-9]", self.bucket):
            raise ValueError("Invalid R2 bucket name")
        self.user = f'{credentials["R2_ACCESS_KEY_ID"]}:{credentials["R2_SECRET_ACCESS_KEY"]}'

    def _curl(self, key, *args):
        url = f"{self.endpoint}/{self.bucket}/{key}"
        config = f'user = "{self.user}"\n'
        result = subprocess.run(
            ["curl", "-sS", "--aws-sigv4", "aws:amz:auto:s3", "-K", "-", "-o", "/dev/null", "-w", "%{http_code}", *args, "--", url],
            input=config.encode(), capture_output=True,
        )
        if result.returncode != 0:
            raise RuntimeError(f"curl failed for {key}: {result.stderr.decode().strip()}")
        return int(result.stdout.decode() or 0)

    def exists(self, key):
        status = self._curl(key, "-I")
        if status not in (200, 404):
            raise RuntimeError(f"Could not check {key} in R2 (HTTP {status})")
        return status == 200

    def put(self, key, path, content_type, cache_control, only_new=False):
        digest = describe(path)["sha256"]
        headers = ["-X", "PUT", "--upload-file", str(path), "-H", f"content-type: {content_type}",
                   "-H", f"cache-control: {cache_control}", "-H", f"x-amz-content-sha256: {digest}"]
        if only_new:
            headers += ["-H", "if-none-match: *"]
        status = self._curl(key, *headers)
        if status == 412:
            raise ValueError(f"{key} already exists")
        if status != 200:
            raise RuntimeError(f"Uploading {key} failed (HTTP {status})")
        print(f"Uploaded {key}", flush=True)


def fetch(url, timeout=120):
    request = urllib.request.Request(url, headers={"cache-control": "no-cache", "user-agent": "gizlet-macos-release"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.read()


def wait_for(url, check, attempts=30, delay=10):
    """Fetches url until check(body) is true, as the site may take a moment to serve new files."""
    last = None
    for _ in range(attempts):
        try:
            body = fetch(url)
            if check(body):
                return body
            last = "unexpected contents"
        except (urllib.error.URLError, OSError) as error:
            last = error
        time.sleep(delay)
    raise RuntimeError(f"{url} is not served as published: {last}")


def published_version(site=SITE):
    """The version latest.json names now, or None when there is none yet."""
    try:
        envelope = json.loads(fetch(f"{site}/assets/{PREFIX}/latest.json"))
        return version_tuple(json.loads(envelope["manifest"])["version"])
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise


def release_artifacts(manifest):
    yield manifest["archive"], "application/zip"
    for image in manifest["dmgs"].values():
        yield image, "application/x-apple-diskimage"


def publish(tag, out, manifest, credentials, site=SITE, allowed_signers=ROOT / "devops/allowed_signers"):
    r2 = R2(credentials)
    folder = f"{PREFIX}/releases/{tag}/"
    if r2.exists(folder + "manifest.json"):
        # An earlier run uploaded this version and stopped before promoting it.
        manifest = published_release(tag, manifest["commit"], out, site, allowed_signers)
        print(f"{tag} is already uploaded; checking and promoting it", flush=True)
    else:
        immutable = "public, max-age=31536000, immutable"
        for file, content_type in release_artifacts(manifest):
            r2.put(folder + file["path"], out / file["path"], content_type, immutable)
        for name, content_type in (("manifest.json.sig", "text/plain; charset=utf-8"),
                                   ("latest.json", "application/json")):
            r2.put(folder + name, out / name, content_type, immutable)
        r2.put(folder + "manifest.json", out / "manifest.json", "application/json", immutable, only_new=True)

    for file, _ in release_artifacts(manifest):
        wait_for(f"{site}/assets/{folder}{file['path']}",
                 lambda body, file=file: len(body) == file["bytes"] and hashlib.sha256(body).hexdigest() == file["sha256"])
        print(f"Verified {site}/assets/{folder}{file['path']}", flush=True)

    current = published_version(site)
    new = version_tuple(manifest["version"])
    if current is not None and current >= new:
        print(f"latest.json stays at {'.'.join(map(str, current))}; {tag} is not newer", flush=True)
        return
    r2.put(f"{PREFIX}/latest.json", out / "latest.json", "application/json", "no-cache")
    expected = (out / "latest.json").read_bytes()
    wait_for(f"{site}/assets/{PREFIX}/latest.json", lambda body: body == expected)
    print(f"Published {tag}: {site}/assets/{PREFIX}/latest.json", flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("tag")
    parser.add_argument("commit")
    parser.add_argument("out", type=Path)
    parser.add_argument("--archive", required=True)
    parser.add_argument("--dmg-arm64", required=True)
    parser.add_argument("--dmg-x86-64", required=True)
    parser.add_argument("--notes", type=Path, required=True)
    parser.add_argument("--assemble-only", action="store_true")
    args = parser.parse_args()
    if not re.fullmatch(f"v{VERSION}", args.tag) or not re.fullmatch(r"[0-9a-f]{40}", args.commit):
        parser.error("expected vMAJOR.MINOR.PATCH and a full commit SHA")
    dmgs = {"arm64": args.dmg_arm64, "x86_64": args.dmg_x86_64}
    for name in (args.archive, *dmgs.values()):
        if "/" in name or not (args.out / name).is_file():
            parser.error(f"{name} is not a file in {args.out}")
    credentials = json.load(sys.stdin)
    manifest = assemble(args.tag, args.commit, args.out, args.archive, dmgs, args.notes.read_text(), credentials["UPDATE_SIGNING_KEY"])
    print(json.dumps(manifest, indent=2))
    if not args.assemble_only:
        publish(args.tag, args.out, manifest, credentials)


if __name__ == "__main__":
    main()
