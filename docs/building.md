# Building and releasing luftig

This page is for people who want to build luftig themselves or publish a release. To just use luftig, see the [README](../README.md).

## Requirements

- A Mac with Apple silicon and macOS 14 or later.
- The Xcode Command Line Tools (`xcode-select --install`) with the Swift 6 toolchain. luftig is a Swift package and builds without Xcode.
- For a release: an Apple Developer ID certificate, notarization credentials, and the GitHub command line tool `gh`.

## Build and run

```sh
Scripts/build-app.sh                            # release build -> build.noindex/luftig.app (ad-hoc signed, verified)
cp -R build.noindex/luftig.app /Applications/   # install
```

An ad-hoc build asks once more for folder access after every rebuild. The build folder is called `build.noindex` so that Spotlight skips it; otherwise the Finder's "Open With" lists two copies of luftig.

luftig runs as a single instance: a second copy that is launched hands its files to the one that is running and quits. To try a build while the installed luftig is open, quit that one first.

## Tests

```sh
swift run -c release mdkit-checks                                                   # the Markdown lexer: about 1,900 checks
Scripts/build-app.sh --selftest                                                     # the self-test variant of the app
build.noindex/luftig-SelfTest.app/Contents/MacOS/luftig-SelfTest --selftest all     # 120 scenarios, about 4,540 checks, ~16 minutes
```

The self-test drives the real app without a screen: the file handling, the editor through real key events, the pixels it draws, the colour contrast of every scheme, memory and speed. `--selftest list` names every scenario, and a comma-separated list runs a few. Two scenarios measure a window that is half a point wider after an appearance change on some machines; [ARCHITECTURE.md](ARCHITECTURE.md) explains the known environmental failures.

A few tools in the self-test variant work on screen and are not part of `all`: `shot-window` makes the README screenshots, `scroll-probe` types into a real window and logs every movement of the view, and `schemes-dump` writes the colours for the scheme overview (`Scripts/make-schemes-svg.py` draws it).

## Releasing

1. Put the Developer ID Application certificate in the keychain, and store notarization credentials once under the profile `luftig`:

   ```sh
   xcrun notarytool store-credentials luftig --key <AuthKey.p8> --key-id <key id> --issuer <issuer id>
   ```

2. Raise `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist`, run the full self-test suite, commit and push `main`.
3. Run `Scripts/release.sh`. It runs the quick checks, builds and signs with the hardened runtime, notarizes and staples the app, makes a DMG with a link to Applications, notarizes and staples that too, tags `v<version>`, publishes a GitHub release with the DMG and its SHA-256, and updates the Homebrew cask.

`Scripts/release.sh --dry-run` does everything except the tag, the release and the cask. The first notarization of a new developer account can take up to an hour; later ones take minutes.

## Homebrew

The cask lives in [bernorieder/homebrew-luftig](https://github.com/bernorieder/homebrew-luftig). `Scripts/release.sh` expects a checkout of it next to this repository (`../homebrew-luftig`, or set `LUFTIG_TAP_DIR`) and commits and pushes the new version and checksum. The official homebrew-cask repository accepts an app once its repository is well known; until then, the tap is the way in.

## Website

[luftig.polsys.net](https://luftig.polsys.net) is served by GitHub Pages from the `docs/` folder of `main`: `index.html`, `privacy.html` and `site.css`, with the `CNAME` file for the domain.
