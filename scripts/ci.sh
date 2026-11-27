#!/usr/bin/env bash
# The CI check: builds the app with xcodebuild, runs every test, and checks
# the release tools. Needs Xcode 16 or later. No credentials: builds are
# signed ad hoc.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "${root}"
derived=build/ci
arch=$(uname -m)
mkdir -p build

xcodebuild -version

# The project is generated from project.yml; a stale one fails the check.
if command -v xcodegen >/dev/null; then
    xcodegen generate --quiet
    git diff --exit-code --stat -- Gizlet.xcodeproj ||
        { echo '::error::Gizlet.xcodeproj does not match project.yml; run xcodegen generate and commit it.'; exit 1; }
fi

rm -rf "${derived}/tests.xcresult"
set +e
xcodebuild test \
    -project Gizlet.xcodeproj -scheme Gizlet \
    -destination "platform=macOS,arch=${arch}" \
    -derivedDataPath "${derived}" \
    -resultBundlePath "${derived}/tests.xcresult" \
    CODE_SIGN_IDENTITY=- > build/ci-test.log 2>&1
status=$?
set -e
grep -E '(Test run|✘|error:|\*\* TEST)' build/ci-test.log || true
[ "${status}" = 0 ] || { tail -n 80 build/ci-test.log; exit "${status}"; }

# The universal Release build that releases sign.
set +e
xcodebuild build \
    -project Gizlet.xcodeproj -scheme Gizlet -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "${derived}" \
    ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY=- > build/ci-build.log 2>&1
status=$?
set -e
grep -E '(error:|warning:|\*\* BUILD)' build/ci-build.log || true
[ "${status}" = 0 ] || { tail -n 80 build/ci-build.log; exit "${status}"; }
app="${derived}/Build/Products/Release/Gizlet.app"
archs=$(lipo -archs "${app}/Contents/MacOS/Gizlet")
[[ " ${archs} " == *" arm64 "* && " ${archs} " == *" x86_64 "* ]] || { echo "error: not universal: ${archs}" >&2; exit 1; }
codesign --verify --strict "${app}"

# Release tooling.
for script in scripts/*.sh; do bash -n "${script}"; done
python3 -I -m unittest discover -s devops -p 'test_*.py'
echo 'CI passed.'
