# Gizlet for macOS

Gizlet Launcher for macOS: discover, install and play Gizlet games and apps on a Mac, keep a profile for everyone who plays, and write Gizlet OS to an SD card for the R36S handheld. A native Swift and SwiftUI app for macOS 14 or later, on Apple silicon and Intel.

Download the latest release from [gizlet.io/install](https://gizlet.io/install), or directly: <https://gizlet.io/assets/macos/download>.

## Features

- **Discover, Games and Apps.** The [Gizlet Store](https://gizlet.io)'s featured gizlets, cover art, search from the sidebar, and each gizlet's page with screenshots and controls. The Store lists every gizlet; one with a package for this Mac's architecture (`aarch64-apple-darwin`, or `x86_64-apple-darwin`, under Rosetta too) has **Get**, the others are marked **Handheld**. Installed gizlets show **Play** or **Update**.
- **Library.** The installed games and apps as cover tiles: play, quit, favorite, update, uninstall and show their saves. Install a local `.gzl` from the toolbar, with ⌘O, or by opening it in Finder.
- **Profiles.** Installed packages are shared; each profile keeps its own saves, favorites, recently played order, language and appearance. Switching from the sidebar takes effect at once.
- **Flash.** Writes the latest Gizlet OS release, or a local `.img` or `.img.gz`, to a whole TF card for the R36S, reads it all back to compare, and selects the card's display panel.
- **Updates.** Checks for a new Launcher when it starts and every two minutes, installs it after asking, and lists the installed apps' Store updates.
- English and Simplified Chinese, light and dark appearance, and keyboard navigation throughout.

## Build and test

Needs Xcode 16 or later on macOS 14 or later. The app target is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen); the logic and UI live in the `GizletKit` Swift package.

```sh
scripts/ci.sh                 # what CI runs: tests, a universal Release build, release tool tests
open Gizlet.xcodeproj         # run the Gizlet scheme
xcodegen generate             # after changing project.yml
```

Without Xcode, the Command Line Tools build and test the package and a development app:

```sh
cd GizletKit
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
swift test -Xswiftc -F$F -Xlinker -F$F -Xlinker -rpath -Xlinker $F
cd .. && scripts/dev-app.sh --open    # build/dev/Gizlet Dev.app
```

| Variable | Effect |
| --- | --- |
| `GIZLET_PREFIX` | Data folder instead of `~/Library/Application Support/Gizlet` |
| `GIZLET_STORE_API` | Another Store API (HTTPS, or localhost), such as a local `pnpm dev` of gizlet/gizlet at `http://localhost:8787/api` |
| `GIZLET_UPDATE_FEED` | Another update manifest URL, for testing a release |
| `GIZLET_ALLOW_DISK_IMAGES=1` | Lists attached disk images in Flash, to test writing without a card |
| `GIZLET_PAGE` | The page to open on: `discover`, `games`, `apps`, `library`, `updates`, `flash` or `settings` |

## Layout

| Path | Contents |
| --- | --- |
| `App/` | The app target's entry point, icon and generated `Info.plist` |
| `GizletKit/Sources/GizletCore/` | Packages (`ZipArchive`, `Manifest`, `AppLibrary`), profiles, the Store client and installer, the OS release feed, image preparation, disks (`Disks`, `AuthOpen`, `CardWriter`, `R36SPanel`) and updates (`SSHSignature`, `LauncherUpdate`, `UpdateInstaller`) |
| `GizletKit/Sources/GizletUI/` | The SwiftUI app: models for the window, Store, Flash and updates, and their views |
| `GizletKit/Tests/GizletCoreTests/` | Swift Testing suites, with a signed Gizlet OS manifest and a signed update manifest as fixtures |
| `scripts/` | `ci.sh`, `release.sh`, `dev-app.sh` and `import-developer-id.sh` |
| `devops/` | `release.py` (update manifest and R2 upload) with its tests, `allowed_signers`, the Apple intermediate and `secrets/release.enc.yaml` |
| `design/app-icon.svg` | The icon's source; `App/Resources/Assets.xcassets` holds its rendered sizes |

## Data

`~/Library/Application Support/Gizlet` is laid out as a Gizlet OS card's data partition:

| Path | Holds |
| --- | --- |
| `device/packages/apps/<id>/` | An installed package, shared by every profile |
| `device/packages/apps/<id>/` extended attribute `io.gizlet.store-origin` | The source repository and GitHub repository id used to match Store updates. Older installs fall back to `device/store/origins.json`. |
| `device/current-profile` | The profile in use |
| `device/launcher/updates/` | Launcher updates being verified |
| `profiles/<id>/profile.ini` | A profile's name |
| `profiles/<id>/launcher/settings.ini`, `recent.ini` | Its language, appearance and favorites; when each app last ran |
| `profiles/<id>/apps/<app-id>/` | An app's saves, `GIZLET_SAVE_DIR`; kept when the app is uninstalled |

Installing checks the package as Gizlet OS does: a zip of stored or deflated entries with canonical relative names, no links, devices, setuid files, encryption or ZIP64, names that do not collide by case or Unicode form, and every file matching `CHECKSUMS`. Its `manifest.json` must be an app for this Mac's target and tier, and its entry a Mach-O executable of that CPU (or a script). It is unpacked beside the installed version and swapped in whole. An app runs with its folder as the working directory and `GIZLET_APP_ID`, `GIZLET_APP_DIR`, `GIZLET_SAVE_DIR`, `GIZLET_LANG` and `GIZLET_PROFILE_ID`.

## Writing a card

Flash lists the external and removable disks Disk Arbitration reports, as they are inserted, unmounted and ejected. The startup disk and every disk behind its APFS container, the disks holding the app and its data, internal fixed disks, disk images, APFS containers and write-protected cards are never offered. A card's FAT boot partition tells its panel: a stock card's kernel dtb names the controller, and a Gizlet OS card keeps the overlay it was written with.

The latest release is found through `gizlet.io/api/v1/os/releases/latest`; its manifest must be signed with the Gizlet OS release key and the image must match `SHA256SUMS`. A `.img.gz` is unpacked and its gzip CRC checked before the card is touched. After the user confirms the exact card (and types its name when it is over 256 GB), the card is unmounted and macOS's `authopen` asks for an administrator password and passes back only the open device. The card's identity, including when it appeared, is checked before authorization, after it, and against the opened device, so a card taken out or swapped needs confirming again. The image is written in whole sectors, flushed, and read back and compared byte for byte; then the panel overlay is copied to `mipi-panel.dtbo` and the card is ejected.

## CI and code review

Pull requests to `main` need two checks, set up from the shared [Gizlet workflows](https://github.com/gizlet/.github). When a pull request from a branch in this repository is opened, pushed to, reopened or marked ready, `triage.yml` has gizlet-bot comment `/ci` and `/codex-review` for its head; a writer can comment either again. Fork pull requests are never built.

- `CI` (`ci.yml`) runs `scripts/ci.sh` on the self-hosted Mac that the `RUNNERS` organization variable maps to `macos-arm64`, falling back to GitHub's `macos-26` runner. The job checks out the pull request with a read-only token and no secrets, and builds are signed ad hoc.
- `Codex Code Review` (`codex-review.yml`) reviews the diff, with attention to disk-writing target checks, privilege boundaries, update verification and profile data.

Merging uses squash commits; `main` requires both checks.

## Releases and updates

Push a `vMAJOR.MINOR.PATCH` tag (minor and patch below 100) on a commit in `main`, annotated with the release notes. The Release workflow (`release.yml`) runs `scripts/ci.sh` and `scripts/release.sh`, the only job given the `SOPS_AGE_KEY` organization secret, which decrypts `devops/secrets/release.enc.yaml`. It runs where pull-request code never ran: the runner `RUNNERS` maps to `macos-arm64-release`, which must not also serve `macos-arm64`, or else GitHub's `macos-26`, a fresh virtual machine for each job. A persistent Mac that builds pull requests could keep something running that captures the next release's credentials.

1. Imports the Developer ID Application identity of team `D82Y886BX5` into a temporary keychain, and archives a universal `Gizlet.app` with the hardened runtime and a secure timestamp.
2. Notarizes the app with the App Store Connect API key, staples the ticket, and checks it with `spctl`; packs it as `Gizlet-<version>.zip` for updates.
3. Builds separate `Gizlet-<version>-arm64.dmg` and `Gizlet-<version>-x86_64.dmg` installers. CI notarizes and staples each image and checks both the image and its app with Gatekeeper.
4. `devops/release.py` writes `manifest.json` with the version, minimum macOS, notes, and the size and SHA-256 of both installers and the universal update ZIP. The manifest retains `dmg` as an alias for `dmgs.arm64` for schema 1 update clients. The script signs the manifest with `ssh-keygen -Y sign` (namespace `gizlet-macos-update`) and uploads `macos/releases/<tag>/` to the `gizlet-assets` R2 bucket. The signed manifest is uploaded last, and existing releases are immutable.
5. After every file downloads from `https://gizlet.io/assets/macos/releases/<tag>/` with its SHA-256, it uploads `macos/latest.json` (the manifest's text and signature), unless a newer version is already there.

A last job attaches both DMGs and the signed manifest to a GitHub release. gizlet.io serves version folders as immutable and `latest.json` with `Cache-Control: no-cache`, so each check revalidates it.

The Launcher reads `latest.json` when it starts and every 120 seconds. It verifies the signature with the key built into it (`TrustedKeys.swift`, the same as `devops/allowed_signers`), and offers a newer version that runs on this macOS. Installing downloads the archive, checks its size and SHA-256, and requires exactly one `Gizlet.app` of that version with bundle ID `io.gizlet.macos`, signed by Developer ID team `D82Y886BX5`, notarized, and valid with its nested code. Then it quits, and a helper replaces the app, keeping the old one until the new one is in place, and opens it. A card being written postpones the install; any failed check keeps the running version. Settings can also check at once and open Gizlet at login.

To set up the signing identity, run `scripts/import-developer-id.sh FILE.p12` and enter the file's password; it stores only the Developer ID Application identity under a new password. The notarization key, update key and R2 credentials are in the same file; edit it with `sops devops/secrets/release.enc.yaml`.
