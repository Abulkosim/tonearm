# Contributing

Be kind. This project follows the [code of conduct](CODE_OF_CONDUCT.md).

## Build and run

Needs macOS 13 or later and Xcode 15 or later (Swift 5.9). The only dependency is [Sparkle](https://sparkle-project.org), for updates; SwiftPM fetches it.

```sh
scripts/build-app.sh
open build/Tonearm.app
```

This builds a universal `build/Tonearm.app`, signed ad hoc. Set `SIGN_IDENTITY` to sign with a real certificate.

Run the tests with `swift test`.

For quick iterations, `swift build` and `swift run` work too, but macOS ties the Automation permission to the app bundle, so test permission prompts with the built app.

If you need to see the permission prompt again, see [docs/permissions.md](docs/permissions.md).

## Snapshot

`Tonearm --snapshot out.png` renders the player with sample data to a PNG and exits. It doesn't need Spotify. CI runs it on every pull request and uploads the image as the `snapshots` artifact, so you can check how a UI change looks:

```sh
gh run download <run-id> -n snapshots
```

The README animation, `docs/images/demo.gif`, is rendered the same way. `scripts/make-demo.sh` runs `Tonearm --demo` and joins the frames with [gifski](https://gif.ski). The Demo workflow does this on pull requests that touch `Snapshot.swift` and uploads the GIF as the `demo` artifact. When the player's look changes, download it and commit it.

## State walk

`Tonearm --states <dir>` renders every screen in every state the code has: each Spotify status and permission screen, songs with long, one-letter, right-to-left, Japanese or emoji titles, ads, episodes, local files, no duration, the ends of the progress and volume bars, very light and very dark covers, the compact layout, every part of settings, the welcome window, and the menu bar title on a light and a dark menu bar. It writes one PNG per state, `contact-sheet.png` with all of them captioned, and `report.txt` with their sizes.

A window can't be taller than the screen. The walk measures each window against a small screen, a 13-inch MacBook Air at its Larger Text setting with the Dock at the bottom, and marks one that doesn't fit as CLIPPED. Then the run fails. It also draws each window on an endless screen and reports the full height of its content. Settings scroll when they don't fit; every other window must fit whole. The window and the welcome window are always dark, so their light mode renders must match the dark ones pixel for pixel, or the run fails too.

CI runs it on every pull request and uploads the result as the `states` artifact:

```sh
gh run download <run-id> -n states -D states
open states/contact-sheet.png
```

To run it on a Mac: `scripts/build-app.sh && build/Tonearm.app/Contents/MacOS/Tonearm --states build/states`.

Run it after every visible change and look at every picture, not only the one you meant to change. Look for text cut off mid-word, overlaps, low contrast, things out of line, right-to-left text on the wrong side, controls that look disabled when they aren't, and empty gaps. When you add a screen or a state, add it to `Sources/Tonearm/StateWalk.swift`.

## End-to-end test

The unit tests only parse replies. The E2E workflow tests the whole path: it runs Tonearm against a fake Spotify, `Tools/FakeSpotify`, a small app with bundle id `com.spotify.client` and its own AppleScript dictionary. Tonearm's own scripts go to it as real Apple Events, and it posts the same `PlaybackStateChanged` notification Spotify does. It logs every command it gets, so the test can check that play, seek, volume and the rest arrive with the right values. The scenarios are in `Sources/Tonearm/E2E.swift`. They include ads, podcasts, long non-Latin titles, Spotify quitting in the middle of a read, and Spotify not running at all.

A second job installs the real Spotify on the runner and checks that every term Tonearm sends has the same four-char code in both dictionaries. If you change a script in `SpotifyBridge.swift`, add any new term to `Tools/FakeSpotify/Spotify.sdef` and to the list in `Tools/FakeSpotify/check-sdef.py`.

Logs are in the `e2e-logs` artifact. To run it on a Mac without Spotify installed:

```sh
scripts/e2e.sh
```

macOS asks once whether your terminal may control "Spotify" (on CI the script grants it in the TCC database). Don't run it where the real Spotify is installed: the test refuses to drive anything but the fake.

## Window sizing logs

The menu bar window is sized by `Views/MenuBarWindowFit.swift`, and CI can't open it. To see what it does on a real Mac, run this and open the window:

```sh
log stream --level info --predicate 'subsystem == "io.github.abulkosim.tonearm" AND category == "window"'
```

`fit missed` or `gave up` means something kept the window from reaching the content's size. Running `TONEARM_DEBUG_WINDOW=1 /Applications/Tonearm.app/Contents/MacOS/Tonearm` prints the same lines in the terminal, plus the window's view tree.

## App icon

The icon is drawn in code by `scripts/make-icon.swift`. Run `swift scripts/make-icon.swift` on macOS to regenerate `design/icon-1024.png` and `Resources/AppIcon.icns`, and commit both. The Icon workflow renders it on pull requests that touch the script and uploads a preview.

## Website

`site/index.html` is the page at https://abulkosim.github.io/tonearm/. It is plain HTML and CSS with no build step. The Pages workflow copies `design/icon-1024.png` and `docs/images/player.png` into it and deploys it when `site/` changes on `main`. To preview it:

```sh
cp design/icon-1024.png site/icon.png
cp docs/images/player.png site/player.png
open site/index.html
```

## Homebrew

The cask lives in `packaging/homebrew/Casks/tonearm.rb` and is copied to the tap [Abulkosim/homebrew-tap](https://github.com/Abulkosim/homebrew-tap). It always installs the latest release, so releases don't need to touch it. See [packaging/homebrew/README.md](packaging/homebrew/README.md).

## Pull requests

- Branch from `main`, one change per pull request.
- Titles and commits use [Conventional Commits](https://www.conventionalcommits.org): `type(scope): summary`, imperative, lowercase. For example `fix(bridge): handle spotify quitting mid-read`.
- The commit body says what changed and why.
- CI must pass. Attach the snapshot or a screenshot for visual changes.
- Talk to Spotify only through AppleScript. No Web API, no login, no new third-party packages (Sparkle is the only one).

## Releases

See [docs/releasing.md](docs/releasing.md).
