# Fixing the Spotify permission

Tonearm controls Spotify through Apple Events. macOS asks once whether to allow that. If you clicked "Don't Allow", or the player says Tonearm needs permission, do this.

## Turn it on in System Settings

1. Open System Settings → Privacy & Security → Automation.
2. Find Tonearm in the list and expand it.
3. Turn on Spotify.
4. Quit Tonearm and open it again.

## If Tonearm isn't listed, or the toggle doesn't help

Reset the permission so macOS asks again:

1. Quit Tonearm.
2. In Terminal, run:

   ```sh
   tccutil reset AppleEvents io.github.abulkosim.tonearm
   ```

3. Quit Spotify and open it again.
4. Open Tonearm. macOS shows "Tonearm wants to control Spotify". Click OK.

## After an update

From v0.3.1 on, every release is signed with the same certificate and updates arrive through the app itself (gear → Check for Updates…). macOS sees each update as the same app, so the permission stays and you are not asked again.

You may be asked once more in these cases:

- You move from v0.2.0 or earlier to v0.3.1. Those builds had a different signature. Click OK when macOS asks.
- You build Tonearm from source. Local builds are signed ad hoc, and each build looks like a new app to macOS.

If you missed the prompt, or Tonearm says Spotify isn't running while it is, follow the reset steps above.
