# Contributing

## Build and run

Needs macOS 13 or later and Xcode 15 or later (Swift 5.9). There are no dependencies.

```sh
scripts/build-app.sh
open build/Tonearm.app
```

This builds a universal `build/Tonearm.app`, signed ad hoc. Set `SIGN_IDENTITY` to sign with a real certificate.

For quick iterations, `swift build` and `swift run` work too, but macOS ties the Automation permission to the app bundle, so test permission prompts with the built app.

If you need to see the permission prompt again, see [docs/permissions.md](docs/permissions.md).

## Snapshot

`Tonearm --snapshot out.png` renders the player with sample data to a PNG and exits. It doesn't need Spotify. CI runs it on every pull request and uploads the image as the `snapshots` artifact, so you can check how a UI change looks:

```sh
gh run download <run-id> -n snapshots
```

## App icon

The icon is drawn in code by `scripts/make-icon.swift`. Run `swift scripts/make-icon.swift` on macOS to regenerate `design/icon-1024.png` and `Resources/AppIcon.icns`, and commit both. The Icon workflow renders it on pull requests that touch the script and uploads a preview.

## Pull requests

- Branch from `main`, one change per pull request.
- Titles and commits use [Conventional Commits](https://www.conventionalcommits.org): `type(scope): summary`, imperative, lowercase. For example `fix(bridge): handle spotify quitting mid-read`.
- The commit body says what changed and why.
- CI must pass. Attach the snapshot or a screenshot for visual changes.
- Talk to Spotify only through AppleScript. No Web API, no login, no third-party packages.
