# Homebrew cask

`Casks/tonearm.rb` is a copy of the cask in the tap [Abulkosim/homebrew-tap](https://github.com/Abulkosim/homebrew-tap). Users install with:

```sh
brew install --cask abulkosim/tap/tonearm
```

The cask uses `version :latest` and the stable link `releases/latest/download/Tonearm.dmg`, so it never needs a bump after a release. Homebrew does not upgrade `:latest` casks unless you pass `--greedy`, so `brew upgrade` leaves Tonearm to update itself through Sparkle. (`brew audit` rejects `auto_updates` on a `:latest` cask.)

The `postflight_steps` remove the quarantine flag, because the app is not notarized. Homebrew users don't need Open Anyway.

`brew uninstall --zap --cask tonearm` also removes the settings, caches and the listening history in `~/Library/Application Support/Tonearm`. It does not remove the ListenBrainz token from the Keychain; the README's uninstall steps show how.

## Changing the cask

Change it here and in the tap in the same way, with a pull request in each. The tap's Check casks workflow runs `brew style`, `brew audit --cask --strict --online`, a real install that checks the quarantine flag is gone and the signature holds, and `brew uninstall --zap`, on a Mac, on every pull request.

To try a change on a Mac before it is in the tap:

```sh
brew install --cask ./packaging/homebrew/Casks/tonearm.rb
open -a Tonearm
brew uninstall --zap --cask tonearm
```

## Website

The cask's `homepage` is the GitHub Pages site built from `site/`. `.github/workflows/pages.yml` deploys it on pushes to `main` that touch the site or its pictures. Pages is set to build from workflows (`gh api repos/Abulkosim/tonearm/pages` shows `"build_type": "workflow"`).
