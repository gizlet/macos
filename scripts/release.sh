#!/usr/bin/env bash
# Builds, signs, notarizes and publishes a Launcher release:
#
#   scripts/release.sh vMAJOR.MINOR.PATCH COMMIT
#
# Run by the Release workflow on the macOS runner, with SOPS_AGE_KEY set.
# It decrypts devops/secrets/release.enc.yaml, imports the Developer ID
# identity into a temporary keychain, archives a universal Gizlet.app signed
# with Developer ID and the hardened runtime, has Apple notarize the app and
# the disk image and staples both tickets, checks them with Gatekeeper's own
# assessment, then hands the files to devops/release.py, which signs the
# update manifest and publishes to R2: the version folder first, the
# manifest that points the Launcher at it last.
#
# GIZLET_RELEASE_DRY_RUN=1 stops after the files are built and checked.
set -euo pipefail

tag=${1:?usage: release.sh vMAJOR.MINOR.PATCH COMMIT}
commit=${2:?usage: release.sh vMAJOR.MINOR.PATCH COMMIT}
if [[ ! "${tag}" =~ ^v(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]?)\.(0|[1-9][0-9]?)$ ]]; then
    echo "error: ${tag} is not vMAJOR.MINOR.PATCH (minor and patch below 100)" >&2
    exit 1
fi
# The build number grows with every release: minor and patch in two digits each.
build_number=$((BASH_REMATCH[1] * 10000 + BASH_REMATCH[2] * 100 + BASH_REMATCH[3]))
if [[ ! "${commit}" =~ ^[0-9a-f]{40}$ ]]; then
    echo 'error: give the full commit SHA' >&2
    exit 1
fi
version=${tag#v}
team=D82Y886BX5
root=$(cd "$(dirname "$0")/.." && pwd)
cd "${root}"
out=${root}/build/release/${tag}
rm -rf "${out}"
mkdir -p "${out}"
log() { printf '\n==> %s\n' "$*"; }
secret() { jq -r --arg key "$1" '.[$key] // empty' <<< "${secrets}"; }

secrets=$(sops decrypt --output-type json devops/secrets/release.enc.yaml)
for key in DEVELOPER_ID_P12 DEVELOPER_ID_P12_PASSWORD NOTARY_KEY_ID NOTARY_ISSUER_ID NOTARY_KEY UPDATE_SIGNING_KEY; do
    [ -n "$(secret "${key}")" ] || { echo "error: ${key} is missing from devops/secrets/release.enc.yaml" >&2; exit 1; }
done

# Credentials live in a private folder and a temporary keychain, removed on exit.
private=$(umask 077 && mktemp -d)
keychain=${private}/release.keychain-db
mount=
original_keychains=$(security list-keychains -d user | tr -d '"' | xargs)
cleanup() {
    if [ -n "${mount}" ]; then
        hdiutil detach "${mount}" -quiet || true
    fi
    # shellcheck disable=SC2086
    security list-keychains -d user -s ${original_keychains} 2>/dev/null || true
    security delete-keychain "${keychain}" 2>/dev/null || true
    rm -rf -- "${private}"
}
trap cleanup EXIT

log 'Importing the Developer ID identity'
keychain_password=$(openssl rand -hex 24)
security create-keychain -p "${keychain_password}" "${keychain}"
security set-keychain-settings -lut 7200 "${keychain}"
security unlock-keychain -p "${keychain_password}" "${keychain}"
secret DEVELOPER_ID_P12 | base64 -d > "${private}/identity.p12"
security import "${private}/identity.p12" -k "${keychain}" -f pkcs12 -P "$(secret DEVELOPER_ID_P12_PASSWORD)" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "${keychain_password}" "${keychain}" >/dev/null
# shellcheck disable=SC2086
security list-keychains -d user -s "${keychain}" ${original_keychains}
identity=$(security find-identity -v -p codesigning "${keychain}" | awk -v team="(${team})" 'index($0, "Developer ID Application:") && index($0, team) {print $2; exit}')
[ -n "${identity}" ] || { echo "error: no valid Developer ID Application identity for ${team}" >&2; exit 1; }
secret NOTARY_KEY > "${private}/notary.p8"
notary=(--key "${private}/notary.p8" --key-id "$(secret NOTARY_KEY_ID)" --issuer "$(secret NOTARY_ISSUER_ID)")

log "Archiving Gizlet ${version} (${build_number})"
set +e
xcodebuild archive \
    -project Gizlet.xcodeproj -scheme Gizlet -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "${out}/Gizlet.xcarchive" -derivedDataPath build/release-derived \
    ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
    MARKETING_VERSION="${version}" CURRENT_PROJECT_VERSION="${build_number}" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="${identity}" DEVELOPMENT_TEAM="${team}" \
    OTHER_CODE_SIGN_FLAGS="--keychain ${keychain} --timestamp" > "${out}/archive.log" 2>&1
status=$?
set -e
[ "${status}" = 0 ] || { tail -n 80 "${out}/archive.log"; exit "${status}"; }
app=${out}/Gizlet.app
archived_app=${out}/Gizlet.xcarchive/Products/Applications/Gizlet.app
ditto "${archived_app}" "${app}"

log 'Checking the signature'
codesign --verify --deep --strict --verbose=2 "${app}"
details=$(codesign -dvv "${app}" 2>&1)
grep -q "^TeamIdentifier=${team}$" <<< "${details}" || { echo "error: not signed by ${team}" >&2; exit 1; }
grep -q 'flags=.*runtime' <<< "${details}" || { echo 'error: the hardened runtime is off' >&2; exit 1; }
grep -q '^Timestamp=' <<< "${details}" || { echo 'error: the signature has no secure timestamp' >&2; exit 1; }
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${app}/Contents/Info.plist")" = "${version}" ]
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${app}/Contents/Info.plist")" = io.gizlet.macos ]
lipo -archs "${app}/Contents/MacOS/Gizlet"

# notarize FILE: submits FILE to Apple and waits; fails unless it is accepted.
notarize() {
    local result id status
    result=$(xcrun notarytool submit "$1" "${notary[@]}" --wait --timeout 2h --output-format json) || true
    id=$(jq -r '.id // empty' <<< "${result}")
    status=$(jq -r '.status // empty' <<< "${result}")
    echo "Notarization ${id:-?}: ${status:-no answer}"
    if [ "${status}" != Accepted ]; then
        [ -z "${id}" ] || xcrun notarytool log "${id}" "${notary[@]}" || true
        echo "error: Apple did not accept $(basename "$1")" >&2
        exit 1
    fi
}

log 'Notarizing the app'
ditto -c -k --keepParent "${app}" "${private}/notarize.zip"
notarize "${private}/notarize.zip"
xcrun stapler staple "${app}"
xcrun stapler validate "${app}"
spctl --assess --type execute -vv "${app}" 2>&1 | tee "${out}/gatekeeper-app.txt"
grep -q 'source=Notarized Developer ID' "${out}/gatekeeper-app.txt"

log 'Packing the update archive'
archive=Gizlet-${version}.zip
ditto -c -k --sequesterRsrc --keepParent "${app}" "${out}/${archive}"

build_dmg() {
    local arch=$1 dmg=$2 staging=${out}/dmg-$1
    local thin_app=${staging}/Gizlet.app executable=${staging}/Gizlet.app/Contents/MacOS/Gizlet
    log "Building the ${arch} disk image"
    mkdir -p "${staging}"
    ditto "${archived_app}" "${thin_app}"
    lipo "${executable}" -thin "${arch}" -output "${private}/Gizlet-${arch}"
    install -m 755 "${private}/Gizlet-${arch}" "${executable}"
    codesign --force --sign "${identity}" --keychain "${keychain}" --options runtime --timestamp "${thin_app}"
    codesign --verify --deep --strict "${thin_app}"
    ln -s /Applications "${staging}/Applications"
    hdiutil create -volname "Gizlet ${version} (${arch})" -srcfolder "${staging}" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "${out}/${dmg}"
    codesign --sign "${identity}" --keychain "${keychain}" --timestamp "${out}/${dmg}"
    notarize "${out}/${dmg}"
    xcrun stapler staple "${out}/${dmg}"
    xcrun stapler validate "${out}/${dmg}"
    spctl --assess --type open --context context:primary-signature -vv "${out}/${dmg}" 2>&1 | tee "${out}/gatekeeper-${arch}-dmg.txt"
    grep -q 'source=Notarized Developer ID' "${out}/gatekeeper-${arch}-dmg.txt"

    mkdir -p "${private}/mount-${arch}"
    hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "${private}/mount-${arch}" "${out}/${dmg}"
    mount=${private}/mount-${arch}
    spctl --assess --type execute -vv "${mount}/Gizlet.app" 2>&1 | grep 'source=Notarized Developer ID'
    codesign --verify --deep --strict "${mount}/Gizlet.app"
    [ "$(lipo -archs "${mount}/Gizlet.app/Contents/MacOS/Gizlet")" = "${arch}" ]
    hdiutil detach "${mount}" -quiet
    mount=
}

arm64_dmg=Gizlet-${version}-arm64.dmg
intel_dmg=Gizlet-${version}-x86_64.dmg
build_dmg arm64 "${arm64_dmg}"
build_dmg x86_64 "${intel_dmg}"

notes=$(git tag -l --format='%(contents)' "${tag}" | sed '/-----BEGIN PGP SIGNATURE-----/,$d')
[ -n "${notes}" ] || notes=$(git log -1 --format=%s "${commit}")
printf '%s\n' "${notes}" > "${out}/notes.txt"

publish=(python3 -I devops/release.py "${tag}" "${commit}" "${out}" --archive "${archive}" \
    --dmg-arm64 "${arm64_dmg}" --dmg-x86-64 "${intel_dmg}" --notes "${out}/notes.txt")
if [ "${GIZLET_RELEASE_DRY_RUN:-}" = 1 ]; then
    jq '{UPDATE_SIGNING_KEY}' <<< "${secrets}" | "${publish[@]}" --assemble-only
    log "Built ${out}; nothing was published (dry run)."
    exit 0
fi
log 'Publishing'
jq '{R2_ENDPOINT, R2_BUCKET, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, UPDATE_SIGNING_KEY}' <<< "${secrets}" | "${publish[@]}"
