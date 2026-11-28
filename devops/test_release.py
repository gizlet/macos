import datetime
import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
import urllib.error
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import release  # noqa: E402


class ReleaseFixture(unittest.TestCase):
    """A signing key, its allowed_signers and the files of a built release."""

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.path = Path(self.directory.name)
        self.key = self.path / "key"
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(self.key)], check=True)
        public = (self.path / "key.pub").read_text().split()[:2]
        self.signers = self.path / "allowed_signers"
        self.signers.write_text(f'launcher namespaces="{release.NAMESPACE}" {" ".join(public)}\n')
        self.out = self.path / "out"
        self.out.mkdir()
        (self.out / "Gizlet-1.2.3.zip").write_bytes(b"zip")
        (self.out / "Gizlet-1.2.3.dmg").write_bytes(b"dmg image")

    def tearDown(self):
        self.directory.cleanup()

    def assemble(self, key=None):
        return release.assemble("v1.2.3", "a" * 40, self.out, "Gizlet-1.2.3.zip", "Gizlet-1.2.3.dmg", "Faster.\n",
                                (key or self.key).read_text(), allowed_signers=self.signers,
                                now=datetime.datetime(2026, 11, 28, tzinfo=datetime.timezone.utc))


class AssembleTest(ReleaseFixture):
    def test_writes_a_signed_manifest_the_launcher_reads(self):
        manifest = self.assemble()
        self.assertEqual(manifest["version"], "1.2.3")
        self.assertEqual(manifest["minimum_macos"], "14.0")
        self.assertEqual(manifest["dmg"]["bytes"], 9)
        self.assertEqual(manifest["archive"], {"path": "Gizlet-1.2.3.zip", "sha256": hashlib.sha256(b"zip").hexdigest(), "bytes": 3})
        envelope = json.loads((self.out / "latest.json").read_text())
        self.assertEqual(envelope["schema"], 1)
        self.assertEqual(json.loads(envelope["manifest"]), manifest)
        # The signature covers the manifest's exact text.
        signature = self.path / "sig"
        signature.write_text(envelope["signature"])
        subprocess.run(["ssh-keygen", "-Y", "verify", "-f", str(self.signers), "-I", "launcher", "-n", release.NAMESPACE, "-s", str(signature)],
                       input=envelope["manifest"].encode(), check=True, capture_output=True)
        tampered = subprocess.run(["ssh-keygen", "-Y", "verify", "-f", str(self.signers), "-I", "launcher", "-n", release.NAMESPACE, "-s", str(signature)],
                                  input=envelope["manifest"].replace("1.2.3", "1.2.4").encode(), capture_output=True)
        self.assertNotEqual(tampered.returncode, 0)

    def test_refuses_another_key(self):
        other = self.path / "other"
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(other)], check=True)
        with self.assertRaises(ValueError):
            self.assemble(other)

    def test_compares_versions(self):
        self.assertLess(release.version_tuple("0.9.9"), release.version_tuple("0.10.0"))
        for bad in ("1.0", "01.0.0", "1.0.0-beta"):
            with self.assertRaises(ValueError):
                release.version_tuple(bad)

    def test_checks_the_r2_endpoint(self):
        with self.assertRaises(ValueError):
            release.R2({"R2_ENDPOINT": "https://example.com", "R2_BUCKET": "gizlet-assets", "R2_ACCESS_KEY_ID": "a", "R2_SECRET_ACCESS_KEY": "b"})


class PublishTest(ReleaseFixture):
    """publish() against a fake bucket that the fake site serves from."""

    def setUp(self):
        super().setUp()
        self.site = {}
        self.puts = []
        test = self

        class FakeR2:
            def exists(self, key):
                return f"{release.SITE}/assets/{key}" in test.site

            def put(self, key, path, content_type, cache_control, only_new=False):
                url = f"{release.SITE}/assets/{key}"
                if only_new and url in test.site:
                    raise ValueError(f"{key} already exists")
                test.puts.append(key)
                test.site[url] = path.read_bytes()

        def fetch(url, timeout=120):
            if url not in test.site:
                raise urllib.error.HTTPError(url, 404, "Not found", {}, None)
            return test.site[url]

        self.saved = (release.R2, release.fetch)
        release.R2 = lambda credentials: FakeR2()
        release.fetch = fetch

    def tearDown(self):
        release.R2, release.fetch = self.saved
        super().tearDown()

    def publish(self):
        manifest = self.assemble()
        release.publish("v1.2.3", self.out, manifest, {}, allowed_signers=self.signers)
        return manifest

    def latest(self):
        return json.loads(self.site[f"{release.SITE}/assets/macos/latest.json"])

    def test_uploads_the_version_then_promotes_it(self):
        manifest = self.publish()
        self.assertEqual(self.puts[-2:], ["macos/releases/v1.2.3/manifest.json", "macos/latest.json"])
        self.assertEqual(json.loads(self.latest()["manifest"]), manifest)

    def test_a_rerun_finishes_with_what_was_uploaded(self):
        first = self.publish()
        # The run stopped before promoting the version.
        del self.site[f"{release.SITE}/assets/macos/latest.json"]
        self.puts.clear()
        (self.out / "Gizlet-1.2.3.zip").write_bytes(b"rebuilt zip")
        self.publish()
        self.assertEqual(self.puts, ["macos/latest.json"])
        self.assertEqual(json.loads(self.latest()["manifest"]), first)

    def test_a_rerun_refuses_another_commit(self):
        self.publish()
        del self.site[f"{release.SITE}/assets/macos/latest.json"]
        manifest = self.assemble()
        manifest["commit"] = "b" * 40
        with self.assertRaises(ValueError):
            release.publish("v1.2.3", self.out, manifest, {}, allowed_signers=self.signers)


class RepositoryKeyTest(unittest.TestCase):
    def test_allowed_signers_matches_the_launcher(self):
        """The key releases are signed with is the one the app trusts."""
        trusted = release.trusted_key(release.ROOT / "devops/allowed_signers")
        swift = (release.ROOT / "GizletKit/Sources/GizletCore/TrustedKeys.swift").read_text()
        self.assertIn(f'launcherUpdate = "{" ".join(trusted)}"', swift)
        self.assertIn(f'launcherUpdateNamespace = "{release.NAMESPACE}"', swift)


if __name__ == "__main__":
    unittest.main()
