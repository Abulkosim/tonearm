# Releasing Tonearm

A release is a pushed `vX.Y.Z` tag. [`release.yml`](../.github/workflows/release.yml) builds the app, signs it, packages it and publishes a GitHub release. Nobody builds release files by hand.

## Cut a release

1. Make sure CI is green on `main`.
2. Set `CFBundleShortVersionString` in `Resources/Info.plist` to `X.Y.Z`.
3. Write `changelogs/vX.Y.Z.md`: first line `# vX.Y.Z`, then the date and download link, then short bullets about what users will notice. Copy the layout of [v0.1.0](../changelogs/v0.1.0.md).
4. Add a row to the top of the table in `CHANGELOG.md` that links the new file.
5. Check: `scripts/check-release.sh vX.Y.Z`. CI runs the same check for the version in `Info.plist`.
6. Merge these changes to `main` through a pull request.
7. Tag the merge commit and push the tag:

   ```sh
   git switch main && git pull
   git tag -a vX.Y.Z -m vX.Y.Z
   git push origin vX.Y.Z
   ```

8. Watch the run: `gh run watch -R Abulkosim/tonearm $(gh run list -R Abulkosim/tonearm -w release.yml -L 1 --json databaseId -q '.[0].databaseId')`.
9. Download the DMG from the release, install it on a Mac and check that it plays, pauses, skips and shows the cover.

A release that is already published is never replaced; the workflow refuses. To fix a bad release, ship a new patch version.

## What the workflow does

- **prepare** (Ubuntu, read-only): runs `scripts/check-release.sh` on the tag. It fails if the tag is not `vX.Y.Z`, if `changelogs/vX.Y.Z.md` or its `CHANGELOG.md` row is missing, or if `Info.plist` has another version.
- **build** (macos-15, read-only): `scripts/build-app.sh` builds a universal (arm64 and x86_64) app, writes the version and the run number into its `Info.plist`, and signs it with the hardened runtime. `scripts/package.sh` makes `Tonearm-X.Y.Z.zip`, `Tonearm-X.Y.Z.dmg` (with an Applications link) and `SHA256SUMS.txt`. A last step unzips the app and checks the signature, the Apple Events entitlement, the runtime flag, both architectures and the version.
- **release** (Ubuntu): verifies the checksums, records build provenance for the zip, the DMG and `SHA256SUMS.txt`, and creates the release with `gh release create`. The notes are `changelogs/vX.Y.Z.md` plus an install section that says how the build was signed. This is the only job with write access, and it alone gets the OIDC token and attestation permissions.

Actions are pinned to commit SHAs. Dependabot proposes updates weekly.

### Dry runs

Pull requests that change the release workflow or the packaging scripts run it as a dry run. After `release.yml` is on `main`, you can also start one by hand:

```sh
gh workflow run release.yml -R Abulkosim/tonearm -f version=0.0.0-test
```

A dry run builds and uploads the files as a `release-<version>` artifact. It never creates a release. It signs with your certificate only if you pass `-f sign=true`; pull requests never get the secrets.

CI also runs `scripts/package.sh` on every pull request, so packaging breaks show up before a tag does.

## Signing and notarization

Without an Apple Developer ID, the app is ad-hoc signed (`codesign --sign -`). It still has the hardened runtime and the Apple Events entitlement, but macOS blocks the first launch because it is not notarized. The release notes say "Not notarized" and explain Open Anyway in System Settings > Privacy & Security.

Ad-hoc signing has a second cost. macOS ties the "control Spotify" permission (Privacy & Security > Automation) to the app's code signature. An ad-hoc signature is just a hash of the code, and that hash changes with every build, so macOS may ask for the permission again after each update. A Developer ID signature stays the same across versions, so the permission carries over.

When the secrets below exist, tag builds are signed with the Developer ID, the hardened runtime and a secure timestamp. With notarization secrets too, the workflow sends the app and then the DMG to Apple with `xcrun notarytool submit --wait`, staples both tickets with `xcrun stapler staple`, and checks them with `spctl -a -vv`. The DMG is also signed.

### Add the secrets

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

6. Test before the next tag: `gh workflow run release.yml -R Abulkosim/tonearm -f version=0.0.0-test -f sign=true`. The "Signing mode" step should print `notarized`, and the Package step should end with `source=Notarized Developer ID`.
7. Delete the `.p12` and `.p8` files from your disk, or keep them only in a password manager.

The certificate is imported into a temporary keychain that the job deletes at the end. If `MACOS_CERT_P12` is set but its password or identity is missing, the build fails instead of quietly falling back to ad-hoc signing.

The first Developer ID release changes the signature, so macOS asks for the Automation permission one more time. After that it stays.

## Why no App Sandbox

Tonearm is not sandboxed. Under the hardened runtime it only needs `com.apple.security.automation.apple-events` (in `Resources/Tonearm.entitlements`) to send Apple Events. A sandboxed app would also need the `com.apple.security.temporary-exception.apple-events` entitlement listing `com.spotify.client`. That is a temporary exception Apple discourages, and it buys nothing here: the app is not in the Mac App Store, and notarization does not require the sandbox.
