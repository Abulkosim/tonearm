# Releasing Tonearm

A release is a pushed `vX.Y.Z` tag. [`release.yml`](../.github/workflows/release.yml) builds the app, signs it, packages it, writes the update feed and publishes a GitHub release. Nobody builds release files by hand.

## Cut a release

1. Make sure CI is green on `main`.
2. In `Resources/Info.plist`, set `CFBundleShortVersionString` to `X.Y.Z` and `CFBundleVersion` to the output of `scripts/build-number.sh X.Y.Z` (see [Version numbers](#version-numbers)).
3. Write `changelogs/vX.Y.Z.md`: first line `# vX.Y.Z`, then the date and download link, then short bullets about what users will notice. Copy the layout of [v0.1.0](../changelogs/v0.1.0.md). The bullets also show in the update window, so write them for users.
4. Add a row to the top of the table in `CHANGELOG.md` that links the new file.
5. Check: `scripts/check-release.sh vX.Y.Z`. CI runs the same check for the version in `Info.plist`.
6. Merge these changes to `main` through a pull request.
7. Tag the merge commit and push the tag:

   ```sh
   git switch main && git pull
   git tag -a vX.Y.Z -m vX.Y.Z
   git push origin vX.Y.Z
   ```

8. Watch the run: `gh run watch -R Abulkosim/tonearm $(gh run list -R Abulkosim/tonearm -w release.yml -L 1 --json databaseId -q '.[0].databaseId')`. The summary shows the signing mode and `Appcast: signed`.
9. Download the DMG from the release, install it on a Mac and check that it plays, pauses, skips and shows the cover. On a Mac with the previous version, open Settings and click Check for Updates….

A release that is already published is never replaced; the workflow refuses. To fix a bad release, ship a new patch version.

## What the workflow does

- **prepare** (Ubuntu, read-only): fails at once if `SPARKLE_ED_PRIVATE_KEY` is not set. Runs `scripts/check-release.sh` on the tag. It fails if the tag is not `vX.Y.Z`, if `changelogs/vX.Y.Z.md` or its `CHANGELOG.md` row is missing, or if `Info.plist` has another version or build number. It computes the build number with `scripts/build-number.sh`.
- **build** (macos-15, read-only):
  - `scripts/build-app.sh` builds a universal (arm64 and x86_64) app, copies `Sparkle.framework` into `Contents/Frameworks`, writes the version and build number into `Info.plist`, and signs everything inside-out. Only Developer ID builds get the hardened runtime: in ad-hoc and self-signed builds its library validation would stop the app from loading Sparkle, because those signatures have no Team ID.
  - `scripts/package.sh` makes `Tonearm-X.Y.Z.zip`, `Tonearm-X.Y.Z.dmg` (with an Applications link), the same two files as `Tonearm.zip` and `Tonearm.dmg`, and `SHA256SUMS.txt`.
  - `scripts/check-app.sh` unzips the app and runs the launch gate on it (see [Release gates](#release-gates)).
  - `scripts/sparkle-tools.sh` downloads Sparkle's `sign_update` for the pinned version and checks its SHA-256. `scripts/appcast.sh` signs the versioned zip and writes `appcast.xml`, then checks the signature with `sign_update --verify` and with OpenSSL against the `SUPublicEDKey` in the built app.
- **update-e2e** (macos-15, read-only, no secrets): `update-e2e.yml` builds the tagged commit twice and checks that the old build installs the new one through Sparkle (see [Release gates](#release-gates)). It runs next to **build**.
- **release** (Ubuntu), only after **build** and **update-e2e** pass: verifies the checksums, checks the appcast signature again against the `SUPublicEDKey` in the tagged `Info.plist`, records build provenance for every file, and creates the release with `gh release create --latest`. The notes are `changelogs/vX.Y.Z.md` plus an install section that says how the build was signed. This is the only job with write access, and it alone gets the OIDC token and attestation permissions.

Actions are pinned to commit SHAs. Dependabot proposes updates weekly.

### Stable links

Each release carries `Tonearm.dmg`, `Tonearm.zip` and `appcast.xml` under fixed names. Because the newest release is marked latest, these always work:

- `https://github.com/Abulkosim/tonearm/releases/latest/download/Tonearm.dmg` (README, Homebrew cask)
- `https://github.com/Abulkosim/tonearm/releases/latest/download/appcast.xml` (the `SUFeedURL` in the app)

Marking an older release as latest by hand would point every installed copy at that release's feed. Don't.

### Dry runs

Pull requests that change the release workflow, the packaging scripts, `Package.swift` or `Info.plist` run it as a dry run. After `release.yml` is on `main`, you can also start one by hand:

```sh
gh workflow run release.yml -R Abulkosim/tonearm -f version=0.0.0-test
```

A dry run builds and uploads the files as a `release-<version>` artifact. It never creates a release. Without `-f sign=true` it signs ad-hoc and signs the appcast with a throwaway key, so every step still runs. With `-f sign=true` it uses the repository secrets, if they exist. Pull requests never get the secrets.

CI also runs on every pull request: an ad-hoc build that is checked and launched, a build signed with a throwaway self-signed certificate that goes through the same import, trust, signing and launch steps as a release, and `scripts/package.sh`. A Swift compiler warning fails the build.

## Release gates

v0.3.0 passed CI and then did not start on any real Mac. These checks exist so that does not happen again. Each one says what it proves and what it can't.

### Launch gate: `scripts/check-app.sh`

Runs on every CI build (ad-hoc and self-signed) and on the packaged app in every release run. Before it starts the app, it applies the rules a real Mac applies, by reading the signatures:

- Every Mach-O in the bundle (Tonearm, Sparkle, Autoupdate, Updater) is signed, passes `codesign --verify --strict`, and is signed by the same certificate and Team ID as the app. Its designated requirement is a cdhash for ad-hoc builds, or names the app's certificate (self-signed) or team (Developer ID).
- Library validation. If an executable has the hardened runtime and not the `com.apple.security.cs.disable-library-validation` entitlement, it must have a Team ID, and every library in the bundle must have the same one. This is the rule v0.3.0 broke: macOS refused Sparkle.framework with "different Team IDs", because a self-signed certificate has no Team ID.
- The entitlements are exactly `Resources/Tonearm.entitlements`.
- `Info.plist` equals `Resources/Info.plist` except the version and build. So a release has the real `SUFeedURL` and `SUPublicEDKey`, and the test overrides in `build-app.sh` can't reach it. `SUPublicEDKey` is base64 of 32 bytes; the release job separately checks that `SPARKLE_ED_PRIVATE_KEY` derives it.
- The minimum macOS is 13.0 in `Info.plist` and in Tonearm's binary, and no Mach-O needs a newer one.

Then it starts the app with `--snapshot` on arm64 and under Rosetta.

`scripts/launch-gate-test.sh` proves the gate works. The self-signed CI job re-signs its build the way v0.3.0 was signed (`--options runtime` with the self-signed certificate) and downloads the published v0.3.0 (pinned by SHA-256). check-app.sh must fail both on library validation, and pass the normal build.

It can't prove: anything macOS checks that is not in this list, like Gatekeeper on a quarantined download, a revoked certificate, or a change in a future macOS. CI runners do not enforce library validation, so the launch at the end proves only that dyld finds Sparkle.

### Live launch

CI opens the ad-hoc and the self-signed build with `open`, the way a user does, and checks the app is still running 10 seconds later. This catches a crash at startup, including in Sparkle's start. On its own it would have passed v0.3.0, because the runner does not enforce library validation.

### Update end to end: `scripts/update-e2e.sh`

Runs in `update-e2e.yml` on pull requests that touch `scripts/`, `Resources/`, `Updater.swift` or the package, and in every release run before publishing. With a throwaway "Tonearm Self-Signed" certificate and an EdDSA key from Sparkle's `generate_keys`, it builds this commit twice: OLD as 0.0.1 (build 1) and NEW as the version in `Info.plist`, both reading a feed on 127.0.0.1. It packages NEW with `package.sh` and `appcast.sh`, serves it with `python3 -m http.server`, installs OLD in a temporary Applications folder and opens it. Nobody clicks anything: Sparkle checks on launch, downloads in the background, and `Updater.swift` installs at once because no Tonearm window is open. Then it does the same again with OLD built from the newest release tag below NEW, with that release's own scripts, so the updater code that runs is the one users have. That build gets the test feed and key and build 1 in its `Info.plist`, and is signed again with the throwaway certificate.

It proves that, with a certificate that has no Team ID: Sparkle finds the item `appcast.sh` writes, downloads the zip `package.sh` makes, accepts its EdDSA signature and the new app's code signature, replaces the app and relaunches it; the new app's `CFBundleVersion` is NEW's, its signature verifies, it passes the launch gate and stays up 10 seconds. It also checks that `build-app.sh` refuses the test feed and key without `TONEARM_TEST_UPDATE=1`.

It can't prove:

- That the exact copy users have installed can update. The release-tag OLD has the same code, but its `Info.plist` and app signature are rebuilt for the test, and it is built on today's runner and Xcode.
- Anything about the real certificate and key. They are secrets the test never sees. The release job checks that the key matches `SUPublicEDKey`.
- Anything about GitHub's download: the feed is local HTTP. The daily feed check covers the public feed.
- Gatekeeper, quarantine, the move to `/Applications`, an admin password prompt, the Spotify permission carrying over, or library validation (the runner does not enforce it; the launch gate does).
- Developer ID or notarized builds.

### Public feed: `feed.yml`

Every day, `scripts/check-feed.sh` fetches the real `SUFeedURL` and checks that its newest item is the latest GitHub release (version, build number, enclosure), that the zip's EdDSA signature verifies with `SUPublicEDKey` from `Resources/Info.plist`, that the zip and `Tonearm.dmg` match the release's `SHA256SUMS.txt`, that the app in the zip has the same version, feed and key, and that `releases/latest/download/Tonearm.dmg` redirects to the latest release. GitHub emails the repository owner when a scheduled run fails. It expects one item in the feed, as `appcast.sh` writes it.

### Still needs a person

Step 9 of [Cut a release](#cut-a-release): download the DMG on a real Mac (so it is quarantined), open it past Gatekeeper, check that it plays and that macOS asks for the Spotify permission, and on a Mac with the previous version, check that Check for Updates… installs the new one.

## Updates (Sparkle)

Tonearm uses [Sparkle](https://sparkle-project.org) 2, its only dependency, pinned to an exact version in `Package.swift`. `scripts/sparkle-tools.sh` pins the same version and the SHA-256 of its tarball; update both together.

How it works for users:

- Once a day (`SUScheduledCheckInterval` 86400) the app reads `appcast.xml` from the latest release. Users can turn this off in Settings.
- A newer `sparkle:version` is downloaded in the background (`SUAutomaticallyUpdate`), checked against `SUPublicEDKey`, and installed the next time no Tonearm window is open. Tonearm restarts by itself.
- Settings > Check for Updates… checks right away and shows Sparkle's window.
- Sparkle starts only in the real app, never for `--snapshot` or in tests. Its XPC services are removed from the bundle: they are only needed by sandboxed apps.

Sparkle accepts an update if its EdDSA signature matches `SUPublicEDKey` in the installed app, or, failing that, if the new app is signed with the same certificate as the installed one (same designated requirement). The new app's own code signature must be valid either way. Having both is what makes key rotation possible.

### Version numbers

Sparkle decides what is newer by comparing `sparkle:version` with the installed app's `CFBundleVersion`. Both come from `scripts/build-number.sh`: major × 10000 + minor × 100 + patch. 0.3.0 is 300, 1.2.3 is 10203. It only grows if minor and patch stay below 100; the script refuses anything else. v0.1.0 and v0.2.0 used the workflow run number, which is lower than 300.

## Signing

The build job picks the first mode whose secrets exist:

| Mode | Secrets | First launch | Spotify permission after an update |
| --- | --- | --- | --- |
| notarized | `MACOS_CERT_P12`, `MACOS_CERT_PASSWORD`, `MACOS_SIGN_IDENTITY` and notary secrets | opens normally | kept |
| developer-id | `MACOS_CERT_P12`, `MACOS_CERT_PASSWORD`, `MACOS_SIGN_IDENTITY` | Open Anyway once | kept |
| self-signed | `SELF_SIGN_CERT_P12`, `SELF_SIGN_CERT_PASSWORD` | Open Anyway once | kept |
| ad-hoc | none | Open Anyway once | asked again |

macOS ties the "control Spotify" permission (Privacy & Security > Automation) to the app's designated requirement. With ad-hoc signing that requirement is a hash of the code, so it changes with every build and macOS asks again after each update. With a certificate it is the bundle id plus the certificate, which stays the same, so the permission carries over. A self-signed certificate does this for free. It does not get past Gatekeeper, so users click Open Anyway once on the first install; updates after that come through Sparkle and are not blocked.

Developer ID builds get a secure timestamp and, with notarization secrets, are sent to Apple with `xcrun notarytool submit --wait`, stapled, and checked with `spctl`. The DMG is signed too. Self-signed and ad-hoc builds get no timestamp, no notarization and an unsigned DMG.

If a certificate secret is set but its password (or identity, for Developer ID) is missing, the build fails instead of falling back to ad-hoc.

### Add the self-signed certificate

Make it once and keep it forever (password manager or an offline backup). Every version must be signed with the same certificate.

```sh
read -rs P12_PASSWORD && export P12_PASSWORD
scripts/make-self-signed-cert.sh ~/.config/tonearm-signing
base64 -i ~/.config/tonearm-signing/tonearm-self-signed.p12 | gh secret set SELF_SIGN_CERT_P12 -R Abulkosim/tonearm
printf '%s' "$P12_PASSWORD" | gh secret set SELF_SIGN_CERT_PASSWORD -R Abulkosim/tonearm
```

The script makes a 20-year RSA certificate with the common name `Tonearm Self-Signed` and the code signing extended key usage, and writes the `.p12` with the legacy PBE-SHA1-3DES encryption that `security import` accepts. In CI, `scripts/import-signing-cert.sh` imports it into a temporary keychain and marks it trusted for code signing, because codesign refuses an untrusted certificate (`CSSMERR_TP_NOT_TRUSTED`). The keychain is deleted at the end of the job.

### Add the Sparkle key

`SUPublicEDKey` in `Info.plist` is the public half of Tonearm's EdDSA (ed25519) key pair. `SPARKLE_ED_PRIVATE_KEY` holds the private half: base64 of the 32-byte seed, the format `generate_keys -x` exports. Set it from the exported file:

```sh
gh secret set SPARKLE_ED_PRIVATE_KEY -R Abulkosim/tonearm < path/to/sparkle-ed25519.key
```

To make a new pair (see [Rotating keys](#rotating-keys) first):

```sh
scripts/sparkle-tools.sh /tmp/sparkle
/tmp/sparkle/bin/generate_keys --account tonearm          # prints the new SUPublicEDKey
/tmp/sparkle/bin/generate_keys --account tonearm -x sparkle-ed25519.key
```

`generate_keys` keeps the key in your login keychain. The workflow passes the key to `sign_update` on standard input, never as an argument, and checks that it matches `SUPublicEDKey` before signing.

Without `SPARKLE_ED_PRIVATE_KEY` a tag push fails before it builds anything. A release without `appcast.xml` would make `releases/latest/download/appcast.xml` return 404, and installed copies would never see another update. Dry runs without the key still sign the appcast with a throwaway key.

### Add Developer ID secrets

You need a paid Apple Developer account.

1. In Xcode (Settings > Accounts > Manage Certificates) or on developer.apple.com, create a **Developer ID Application** certificate.
2. In Keychain Access, export the certificate with its private key as a `.p12` file and set a password.
3. Find the identity name: `security find-identity -v -p codesigning`. It looks like `Developer ID Application: Your Name (TEAMID1234)`.
4. Add the signing secrets:

   ```sh
   base64 -i DeveloperID.p12 | gh secret set MACOS_CERT_P12 -R Abulkosim/tonearm
   gh secret set MACOS_CERT_PASSWORD -R Abulkosim/tonearm
   gh secret set MACOS_SIGN_IDENTITY -R Abulkosim/tonearm --body "Developer ID Application: Your Name (TEAMID1234)"
   ```

5. Add notarization secrets. Either an App Store Connect API key (App Store Connect > Users and Access > Integrations > Team Keys, role Developer):

   ```sh
   base64 -i AuthKey_ABC123.p8 | gh secret set NOTARY_KEY_P8 -R Abulkosim/tonearm
   gh secret set NOTARY_KEY_ID -R Abulkosim/tonearm --body ABC123
   gh secret set NOTARY_ISSUER_ID -R Abulkosim/tonearm --body <issuer uuid>
   ```

   Or an Apple ID with an app-specific password from account.apple.com:

   ```sh
   gh secret set APPLE_ID -R Abulkosim/tonearm --body you@example.com
   gh secret set APPLE_TEAM_ID -R Abulkosim/tonearm --body TEAMID1234
   gh secret set APPLE_APP_PASSWORD -R Abulkosim/tonearm
   ```

6. Delete the `.p12` and `.p8` files from your disk, or keep them only in a password manager.

Moving from self-signed to Developer ID changes the designated requirement: macOS asks for the Spotify permission once more, and Sparkle refuses an update signed by a different certificate unless the EdDSA key stays the same. Keep `SPARKLE_ED_PRIVATE_KEY` unchanged in the same release that switches certificates.

### Test the secrets

```sh
gh workflow run release.yml -R Abulkosim/tonearm -f version=0.0.0-test -f sign=true
```

The "Signing mode" step should print `self-signed` (or `notarized`), the "Inspect packaged app" step should end with `app ok: ... signed by Tonearm Self-Signed`, and the summary should say `Appcast: signed`.

## Rotating keys

Sparkle allows changing one of the two keys at a time, never both in the same release:

- **New EdDSA key** (the old one leaked or was lost): the certificate must not change in the same release. Make a new key with `generate_keys`, put its public key in `SUPublicEDKey`, set the new `SPARKLE_ED_PRIVATE_KEY`, and release. Sparkle accepts that one update because the certificate still matches; versions after it use the new key. Sparkle's check before unpacking falls back only to a matching Developer ID team, which a self-signed certificate does not have, so with self-signing treat the EdDSA key as permanent and keep a backup.
- **New certificate** (self-signed to Developer ID, or a leaked self-signed key): keep the same EdDSA key in that release. Sparkle accepts the update because the EdDSA signature still matches. macOS asks for the Spotify permission one more time.

Changing both at once leaves installed copies unable to update; their users would have to download the new version by hand.

## Users on v0.2.0 and earlier

v0.1.0 and v0.2.0 have no updater, so they never learn about new versions. Those users install v0.3.0 by hand once, from the release page or `releases/latest/download/Tonearm.dmg`. Because v0.2.0 was ad-hoc signed and v0.3.0 is signed with a certificate, macOS asks one last time for permission to control Spotify. v0.3.0 itself never started on real Macs (see the hardened runtime note above), so its users also install v0.3.1 by hand. From v0.3.1 on, updates come through Sparkle and the permission stays.

## Why no App Sandbox

Tonearm is not sandboxed. Under the hardened runtime (Developer ID builds) it only needs `com.apple.security.automation.apple-events` (in `Resources/Tonearm.entitlements`) to send Apple Events. A sandboxed app would also need the `com.apple.security.temporary-exception.apple-events` entitlement listing `com.spotify.client`. That is a temporary exception Apple discourages, and it buys nothing here: the app is not in the Mac App Store, and notarization does not require the sandbox. It also means Sparkle needs none of its XPC services.
