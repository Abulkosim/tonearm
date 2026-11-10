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

## Does it use my Spotify account?

No. It never logs in and doesn't use the Spotify Web API. It asks the Spotify app on your Mac what's playing, the same way a script in Script Editor would.

## Does `brew upgrade` update it?

No, and it doesn't need to. The app updates itself, and the cask is marked `auto_updates`, so Homebrew leaves it alone.
