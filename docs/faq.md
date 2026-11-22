# Questions

## macOS says the item is in use when I replace Tonearm

Finder says "The operation can't be completed because the item "Tonearm" is in use", or that it can't be replaced because it's open. Tonearm is still running in the menu bar. Quit it first:

- Open the player, click the gear, then Quit Tonearm. Or press ⌘Q while the player is open.
- Or in Terminal:

  ```sh
  pkill -x Tonearm
  ```

Then drag the new Tonearm to Applications again. You only need to do this when you install by hand. Automatic updates quit and restart the app themselves.

## Nothing happens when I open it

Tonearm is running, but it has no Dock icon and no main window. Look in the menu bar at the top right of the screen for the song title or a disc icon, and click it.

On a MacBook with a notch, the icon can be hidden behind the notch when the menu bar is full. Quit a few other menu bar apps, or hide system icons in System Settings → Control Center, and it shows up. Choosing Icon only in Tonearm's settings keeps it short after that.

If it's not in the menu bar at all, macOS may have blocked it. See [the first time you open it](../README.md#the-first-time-you-open-it).

## It says Spotify isn't running, but it is

This is almost always the permission. macOS ties it to the app's signature, so after you replace an old version (v0.2.0 or earlier) or a build from source, the saved answer can belong to the old app and Spotify stops replying. Reset it as described in [permissions.md](permissions.md#if-tonearm-isnt-listed-or-the-toggle-doesnt-help), then quit and reopen Spotify and Tonearm.

Tonearm works with the Spotify desktop app only. It can't see Spotify playing in a web browser.

## Why isn't Tonearm notarized or in the App Store?

Both need a paid Apple Developer account, which costs $99 a year. Tonearm is free and has no budget.

Releases are signed with the same certificate every time. macOS sees each update as the same app, so updates install without prompts and keep the Spotify permission. Only the first launch needs Open Anyway.

The App Store also requires the App Sandbox. A sandboxed app needs a special exception from Apple to send Apple Events to Spotify, and that is the only way Tonearm works. More in [releasing.md](releasing.md#why-no-app-sandbox).

To check that a download came from this repository's release workflow, compare it with `SHA256SUMS.txt` on the release, or verify its build attestation:

```sh
gh attestation verify Tonearm.dmg -R Abulkosim/tonearm
```

## Does it work with Apple Music or other players?

No. Tonearm works only with the Spotify desktop app. It talks to Spotify through Spotify's own AppleScript commands, and other players have different ones. It can't see Spotify playing in a browser or on your phone either, though Liner Notes can import those plays from Spotify's data export.

## Does it use my Spotify account or the Spotify Web API?

No. It never logs in and doesn't use the Web API. It asks the Spotify app on your Mac what's playing, the same way a script in Script Editor would.

This is on purpose. The Web API needs every user to log in to Spotify through Tonearm, and Spotify lets an app in [development mode](https://developer.spotify.com/documentation/web-api/concepts/quota-modes) serve only the users its developer adds by hand. Since May 2025 Spotify [gives wider access](https://developer.spotify.com/blog/2025-04-15-updating-the-criteria-for-web-api-extended-access) only to established services. AppleScript needs no login and no approval, and it works with no network.

The cost: Tonearm can only do what Spotify's AppleScript commands allow. It can't show lyrics, your playlists or the queue, or like a song.

## Which Macs does it run on?

Any Mac with macOS 13 Ventura or later, Apple Silicon or Intel. There is one download; it contains both.

The automated tests run on macOS 15: all of them on GitHub's Apple Silicon Macs, and the tests, a build and a launch on an Intel one. GitHub [retired](https://github.blog/changelog/2025-09-19-github-actions-macos-13-runner-image-is-closing-down/) its macOS 13 machines and [then](https://github.blog/changelog/2026-10-01-github-actions-macos-14-runner-image-retirement) its macOS 14 ones, so nothing runs automatically on macOS 13 or 14. If something is wrong there, please [open an issue](https://github.com/Abulkosim/tonearm/issues/new/choose).

macOS 12 and earlier aren't supported: the player uses SwiftUI's menu bar window, which first came in macOS 13.

## What does Tonearm know about me?

Only what is on your Mac. It has no server, no account and no analytics. It makes these network requests:

- the cover image of the song playing, from the address Spotify gives
- once a day, the update feed on Tonearm's latest GitHub release, to check for a new version
- if you turn it on, your listens to ListenBrainz

Liner Notes makes none. Your listening history is a file on your Mac; see the next question.

## Does Tonearm send my listening history anywhere?

No, unless you turn on ListenBrainz. The history is an SQLite file in `~/Library/Application Support/Tonearm` on your Mac. Tonearm has no server and no account, so there is nowhere else for it to go.

If you turn on Send to ListenBrainz in Settings → History and paste your token, Tonearm sends each song you play to ListenBrainz, and nothing else. It is off by default. You can turn recording off, export the history or delete all of it in the same place. More in [history.md](history.md).

## Does `brew upgrade` update it?

No, and it doesn't need to. The app updates itself. The cask always installs the latest release, and Homebrew skips such casks in `brew upgrade` unless you add `--greedy`.
