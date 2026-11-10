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

Release builds may be signed ad hoc instead of with an Apple Developer ID. macOS then treats each new version as a different app and can ask for the permission again. Click OK, or follow the steps above if you missed the prompt.
