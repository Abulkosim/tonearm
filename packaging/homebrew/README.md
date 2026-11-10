# Homebrew cask

`Casks/tonearm.rb` is the cask for the tap [Abulkosim/homebrew-tap](https://github.com/Abulkosim/homebrew-tap). Users install with:

```sh
brew install --cask abulkosim/tap/tonearm
```

The cask uses `version :latest` and the stable link `releases/latest/download/Tonearm.dmg`, so it never needs a bump after a release. `auto_updates true` tells Homebrew that the app updates itself through Sparkle, so `brew upgrade` leaves it alone.

The postflight removes the quarantine flag, because the app is not notarized. Homebrew users don't need Open Anyway.

`brew style` and `brew audit --cask --strict --online` pass on this file.

## Publish it (once)

The tap repo already exists and holds the Wick and Weir casks. Run this on a Mac or Linux machine with `gh` signed in as Abulkosim, after v0.3.0 is released (the cask points at the unversioned `Tonearm.dmg` that releases have from v0.3.0 on):

```sh
gh repo clone Abulkosim/homebrew-tap /tmp/homebrew-tap
curl -fsSL https://raw.githubusercontent.com/Abulkosim/tonearm/main/packaging/homebrew/Casks/tonearm.rb \
  -o /tmp/homebrew-tap/Casks/tonearm.rb
cd /tmp/homebrew-tap
# Replace README.md with the text in "Tap README" below.
git add Casks/tonearm.rb README.md
git commit -m "feat(tonearm): add cask"
git push origin main
```

If the tap did not exist, create it first with `gh repo create Abulkosim/homebrew-tap --public --description "Homebrew casks for Abulkosim's apps"`, then add `Casks/tonearm.rb` and the README.

Check it on a Mac:

```sh
brew install --cask abulkosim/tap/tonearm
open -a Tonearm
brew uninstall --zap --cask tonearm
```

When the cask changes here, copy it to the tap the same way.

## Tap README

Paste this as `README.md` in the tap repo:

````markdown
# Abulkosim's Homebrew tap

```sh
brew install --cask abulkosim/tap/wick
brew install --cask abulkosim/tap/weir
brew install --cask abulkosim/tap/tonearm
```

| Cask | App |
| --- | --- |
| `wick` | [Wick](https://github.com/Abulkosim/wick): a menu bar app that keeps the Mac awake |
| `weir` | [Weir](https://github.com/Abulkosim/weir): a menu bar speed test and connection check |
| `tonearm` | [Tonearm](https://github.com/Abulkosim/tonearm): a menu bar mini player for the Spotify desktop app |

Wick and Weir casks are bumped automatically when a release is published. The Tonearm cask always installs the latest release. The apps are free and open source but not notarized, so macOS blocks the first launch of Wick and Weir: open **System Settings → Privacy & Security** and click **Open Anyway**. The Tonearm cask clears the quarantine flag, so it opens without that step.

The apps update themselves; `brew upgrade` leaves them alone (`auto_updates true`).
````

## Website (once)

The cask's `homepage` is the GitHub Pages site built from `site/`. `.github/workflows/pages.yml` deploys it on pushes to `main` that touch the site, but Pages has to be turned on first:

```sh
gh api -X POST repos/Abulkosim/tonearm/pages -f build_type=workflow
gh workflow run pages.yml -R Abulkosim/tonearm
gh repo edit Abulkosim/tonearm --homepage https://abulkosim.github.io/tonearm/
```
