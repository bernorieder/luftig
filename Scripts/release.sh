#!/bin/bash
# Scripts/release.sh - a public release of luftig: build, sign with the Developer ID, notarize, staple, a DMG, a GitHub release.
#
#   Scripts/release.sh                      everything, for the version in Resources/Info.plist (CFBundleShortVersionString)
#   Scripts/release.sh --dry-run            build, sign, notarize and make the DMG, but create no tag and no GitHub release
#   Scripts/release.sh --skip-notarize      (while trying things out) sign only; Gatekeeper then refuses the download on other Macs
#   Scripts/release.sh --skip-tests         do not run the quick checks first (the lexer checks and the build-script tests)
#
# Needs: the "Developer ID Application" certificate in the keychain (IDENTITY below), notarization credentials stored once with
#   xcrun notarytool store-credentials luftig --apple-id <apple id> --team-id <team id>      (NOTARY_PROFILE below),
# and `gh` logged in. The tree must be clean and on main; the tag v<version> must not exist yet.
#
# What comes out: build.noindex/release/luftig-<version>.dmg (signed, notarized, stapled; the app inside is too), a GitHub release
# "luftig <version>" with the DMG attached and the DMG's SHA-256 in the notes, and the Homebrew tap's cask (../homebrew-luftig) bumped and pushed.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IDENTITY="${LUFTIG_IDENTITY:-Developer ID Application: Bernhard Rieder (LA5LV6543Z)}"
NOTARY_PROFILE="${LUFTIG_NOTARY_PROFILE:-luftig}"
DRY=0; NOTARIZE=1; TESTS=1
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --skip-notarize) NOTARIZE=0 ;;
    --skip-tests) TESTS=0 ;;
    -h|--help) awk 'NR>1 { if ($0 ~ /^#/) print substr($0, 3); else exit }' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "release.sh: unknown argument: $a" >&2; exit 1 ;;
  esac
done
die() { echo "release.sh: error: $*" >&2; exit 1; }
cd "$ROOT"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
TAG="v$VERSION"
OUT="$ROOT/build.noindex/release"
APP="$OUT/luftig.app"
DMG="$OUT/luftig-$VERSION.dmg"
echo "==> luftig $VERSION ($TAG)"

# ---- preconditions
[ -z "$(git status --porcelain)" ] || die "the working tree is not clean"
[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || die "not on main"
if [ "$DRY" = 0 ]; then
  git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && die "the tag $TAG exists already (bump CFBundleShortVersionString in Resources/Info.plist)"
  gh release view "$TAG" >/dev/null 2>&1 && die "a GitHub release $TAG exists already"
fi
security find-identity -v -p codesigning | grep -q "$IDENTITY" || die "the signing identity is not in the keychain: $IDENTITY"
command -v gh >/dev/null || die "gh not found"

# ---- the quick checks (the full self-test suite takes a quarter of an hour: run it by hand before a release)
if [ "$TESTS" = 1 ]; then
  echo "==> checks"
  swift run -c release mdkit-checks 2>&1 | tail -1
  bash Scripts/test-build-app.sh 2>&1 | tail -1
fi

# ---- build and sign
rm -rf "$OUT"; mkdir -p "$OUT"
Scripts/build-app.sh --out "$APP" --identity "$IDENTITY"

# ---- notarize the app (a zip is what the notary service takes for an app), then staple the ticket into the bundle
if [ "$NOTARIZE" = 1 ]; then
  echo "==> notarize the app"
  ditto -c -k --keepParent "$APP" "$OUT/luftig.zip"
  xcrun notarytool submit "$OUT/luftig.zip" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1 | sed 's/^/    /'
  xcrun stapler staple "$APP" 2>&1 | sed 's/^/    /'
  rm -f "$OUT/luftig.zip"
fi

# ---- the DMG: the app and a link to /Applications, compressed, signed, notarized, stapled
echo "==> dmg"
STAGE="$OUT/stage"; rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/luftig.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "luftig $VERSION" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG" 2>&1 | sed 's/^/    /'
if [ "$NOTARIZE" = 1 ]; then
  echo "==> notarize the dmg"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1 | sed 's/^/    /'
  xcrun stapler staple "$DMG" 2>&1 | sed 's/^/    /'
  spctl --assess --type open --context context:primary-signature --verbose "$DMG" 2>&1 | sed 's/^/    /' || true
fi
SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
echo "    $DMG"
echo "    sha256 $SHA"

# ---- the GitHub release
if [ "$DRY" = 1 ]; then echo "==> dry run: no tag, no release"; exit 0; fi
echo "==> github release $TAG"
git tag -a "$TAG" -m "luftig $VERSION"
git push origin "$TAG"
NOTES="$OUT/notes.md"
{
  echo "luftig $VERSION for macOS 14 or later (Apple Silicon). Signed and notarized."
  echo
  echo "Install: open the DMG and drag luftig to Applications. Homebrew: \`brew install bernorieder/luftig/luftig\`."
  echo
  echo "SHA-256 of \`luftig-$VERSION.dmg\`: \`$SHA\`"
} > "$NOTES"
gh release create "$TAG" "$DMG" --title "luftig $VERSION" --notes-file "$NOTES"
echo "==> done: $(gh release view "$TAG" --json url --jq .url)"

# ---- the Homebrew tap (bernorieder/homebrew-luftig, checked out next to this repository): the cask's version and checksum, committed and pushed
TAP="${LUFTIG_TAP_DIR:-$ROOT/../homebrew-luftig}"
if [ -f "$TAP/Casks/luftig.rb" ]; then
  echo "==> homebrew tap"
  sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$TAP/Casks/luftig.rb"
  (cd "$TAP" && git add Casks/luftig.rb && git commit -q -m "luftig $VERSION" && git push -q origin main && echo "    cask updated to $VERSION")
else
  echo "    (no tap checkout at $TAP: update Casks/luftig.rb in bernorieder/homebrew-luftig by hand: version $VERSION, sha256 $SHA)"
fi
