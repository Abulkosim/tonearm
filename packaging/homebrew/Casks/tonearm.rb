cask "tonearm" do
  version :latest
  sha256 :no_check

  url "https://github.com/Abulkosim/tonearm/releases/latest/download/Tonearm.dmg"
  name "Tonearm"
  desc "Menu bar mini player for the Spotify desktop app"
  homepage "https://abulkosim.github.io/tonearm/"

  depends_on macos: :ventura

  app "Tonearm.app"

  # Tonearm is signed but not notarized, so Gatekeeper would block the first
  # launch. Removing the quarantine flag lets it open without "Open Anyway".
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/Tonearm.app"]
  end

  uninstall quit: "io.github.abulkosim.tonearm"

  zap trash: [
    "~/Library/Application Support/io.github.abulkosim.tonearm",
    "~/Library/Application Support/Tonearm",
    "~/Library/Caches/io.github.abulkosim.tonearm",
    "~/Library/HTTPStorages/io.github.abulkosim.tonearm",
    "~/Library/Preferences/io.github.abulkosim.tonearm.plist",
  ]
end
