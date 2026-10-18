#!/bin/bash
#
# build-app.sh - assemble luftig.app from the SwiftPM build, without Xcode.
#
#   Scripts/build-app.sh                     release build  ->  <repo>/build.noindex/luftig.app
#   Scripts/build-app.sh --debug             debug build
#   Scripts/build-app.sh --out /some/dir     ->  /some/dir/luftig.app   (a path ending in .app is used as the bundle itself)
#   Scripts/build-app.sh --selftest          the SELF-TEST VARIANT  ->  <repo>/build.noindex/luftig-SelfTest.app
#
# The self-test variant is the same code built with -Xswiftc -DLUFTIG_SELFTEST: it additionally understands
# `luftig-SelfTest --selftest <scenario|all>` (see README.md). It is a separate bundle (CFBundleIdentifier "<id>.selftest",
# its own exported UTI, document handler rank Alternate, executable luftig-SelfTest) so preferences, recents and Launch Services
# never mix with the real app, and it has its own SwiftPM scratch directory (.build-selftest) so switching variants never
# rebuilds the other one. The normal (default) build contains no test hooks at all; this script verifies that.
#
# Extra options (for parallel work / CI):
#   --scratch-path <dir>   SwiftPM scratch (build) directory, so several builds never contend for <repo>/.build
#   --package-path <dir>   package to build (default: the repo this script lives in)
#   --product <name>       executable product (default: luftig)
#   --info-plist <file>    default: Resources/Info.plist
#   --no-sign              skip codesign
#   --regen-icon           re-draw Resources/AppIcon.icns with Resources/make-icon.swift (overwrites the committed file)
#   -h | --help
#
# What it does: swift build -> Contents/{MacOS,Resources,Info.plist,PkgInfo} -> icon (the committed Resources/AppIcon.icns;
# drawn by Resources/make-icon.swift into the bundle only if the file is missing) -> ad-hoc codesign -> verify (plutil,
# codesign, executable, the executable's minos / SDK stamp, document class present in the binary, no test code in the shipping
# binary). Works from any working directory. It never writes into the source tree (except with --regen-icon).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG=release
OUT="$ROOT/build.noindex/luftig.app"
PKG="$ROOT"
SCRATCH=""
PRODUCT="luftig"
INFO="$ROOT/Resources/Info.plist"
SIGN=1
SELFTEST=0
OUT_GIVEN=0
REGEN_ICON=0

die() { echo "build-app.sh: error: $*" >&2; exit 1; }
usage() { awk 'NR>2 { if ($0 ~ /^#/) print substr($0, 3); else exit }' "${BASH_SOURCE[0]}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --debug) CONFIG=debug ;;
    --release) CONFIG=release ;;
    --out) [ $# -ge 2 ] || die "--out needs a value"; OUT="$2"; OUT_GIVEN=1; shift ;;
    --selftest) SELFTEST=1 ;;
    --scratch-path) [ $# -ge 2 ] || die "--scratch-path needs a value"; SCRATCH="$2"; shift ;;
    --package-path) [ $# -ge 2 ] || die "--package-path needs a value"; PKG="$2"; shift ;;
    --product) [ $# -ge 2 ] || die "--product needs a value"; PRODUCT="$2"; shift ;;
    --info-plist) [ $# -ge 2 ] || die "--info-plist needs a value"; INFO="$2"; shift ;;
    --no-sign) SIGN=0 ;;
    --regen-icon) REGEN_ICON=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done

APP_NAME="luftig"
if [ "$SELFTEST" = 1 ]; then
  APP_NAME="luftig-SelfTest"
  [ "$OUT_GIVEN" = 1 ] || OUT="$ROOT/build.noindex/luftig-SelfTest.app"
  [ -n "$SCRATCH" ] || SCRATCH="$ROOT/.build-selftest"
fi

# --out: a directory (-> <dir>/<name>.app) or a bundle path (*.app)
[ -n "$OUT" ] || die "--out needs a non-empty path"
case "$OUT" in
  *.app) APP="$OUT" ;;
  *)     APP="${OUT%/}/$APP_NAME.app" ;;
esac
case "$APP" in /*) ;; *) APP="$PWD/$APP" ;; esac
# the bundle is deleted and rebuilt below: never do that to something that is not an app bundle
if [ -e "$APP" ] && [ ! -f "$APP/Contents/Info.plist" ]; then die "refusing to replace $APP: it exists and is not an app bundle (no Contents/Info.plist)"; fi

command -v swift    >/dev/null || die "swift not found (install the Xcode Command Line Tools)"
command -v codesign >/dev/null || die "codesign not found"
command -v plutil   >/dev/null || die "plutil not found"
[ -f "$INFO" ] || die "Info.plist not found: $INFO"

SWIFT_ARGS=(-c "$CONFIG" --package-path "$PKG")
[ -n "$SCRATCH" ] && SWIFT_ARGS+=(--scratch-path "$SCRATCH")
[ "$SELFTEST" = 1 ] && SWIFT_ARGS+=(-Xswiftc -DLUFTIG_SELFTEST)

echo "==> swift build ($CONFIG, product $PRODUCT$([ "$SELFTEST" = 1 ] && echo ', SELF-TEST variant'))"
# (the linker prints two harmless "search path ... not found" warnings for the Command Line Tools layout: filtered out)
BUILD_LOG="$(mktemp "${TMPDIR:-/tmp}/luftig-build.XXXXXX")"
trap 'rm -f "$BUILD_LOG"' EXIT
if ! swift build "${SWIFT_ARGS[@]}" --product "$PRODUCT" > "$BUILD_LOG" 2>&1; then
  grep -v "ld: warning: search path .* not found" "$BUILD_LOG" | tail -80
  die "swift build failed"
fi
grep -v "ld: warning: search path .* not found" "$BUILD_LOG" | tail -3
if grep -E "warning:|error:" "$BUILD_LOG" | grep -v "ld: warning: search path .* not found" | grep -q .; then
  echo "    NOTE: the compiler reported warnings:" >&2
  grep -E "warning:|error:" "$BUILD_LOG" | grep -v "ld: warning: search path .* not found" | sort -u | head -20 >&2
fi
BIN_DIR="$(swift build "${SWIFT_ARGS[@]}" --show-bin-path)"
BIN="$BIN_DIR/$PRODUCT"
[ -x "$BIN" ] || die "built executable not found: $BIN"

# The shipping binary must not contain any test hook; the self-test variant must contain them.
# (SwiftPM links with -g: the debug map of the Mach-O records the object file names - even empty ones such as SelfTest.o, whose
# sources are compiled out - so the SHIPPING executable is stripped of debug symbols in the bundle below, then checked.)
STRIP_SHIPPING=0
if [ "$SELFTEST" = 0 ]; then STRIP_SHIPPING=1; else
  grep -aqi 'selftest' "$BIN" || die "the self-test variant does not contain the self-test code"
fi

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$INFO" "$APP/Contents/Info.plist"
if [ "$SELFTEST" = 1 ]; then
  # Same Info.plist, other identity: separate preferences / recents / Launch Services record, never a default handler.
  PB=/usr/libexec/PlistBuddy
  P="$APP/Contents/Info.plist"
  ID="$($PB -c 'Print :CFBundleIdentifier' "$P")"
  $PB -c "Set :CFBundleIdentifier $ID.selftest" "$P"
  $PB -c "Set :CFBundleExecutable luftig-SelfTest" "$P"
  $PB -c "Set :CFBundleName luftig-SelfTest" "$P"
  $PB -c "Set :CFBundleDisplayName luftig-SelfTest" "$P"
  # rank None: the test variant is never offered as a handler for anything (Open With, defaults), even though Launch Services
  # registers every bundle that is launched. (It declares no exported types either: those would change how every app sees a file.)
  n=0
  while $PB -c "Print :CFBundleDocumentTypes:$n:LSHandlerRank" "$P" >/dev/null 2>&1; do
    $PB -c "Set :CFBundleDocumentTypes:$n:LSHandlerRank None" "$P"; n=$((n+1))
  done
fi
EXE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist" 2>/dev/null || echo luftig)"
cp "$BIN" "$APP/Contents/MacOS/$EXE_NAME"
if [ "$STRIP_SHIPPING" = 1 ]; then
  strip -S "$APP/Contents/MacOS/$EXE_NAME"
  # (grep on the file itself: `strings | grep -q` under pipefail can lose the match to SIGPIPE and let a leak through)
  if grep -aqiE 'selftest|LuftigReport|LuftigLaunchProbe|LuftigCommands' "$APP/Contents/MacOS/$EXE_NAME"; then
    die "the shipping binary contains self-test code or strings - LUFTIG_SELFTEST must not be defined for it"
  fi
  echo "    verified: no 'selftest' symbols or strings in the shipping binary (debug symbols stripped)"
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"
# SwiftPM resource bundles (none today; harmless if a target adds some)
for b in "$BIN_DIR"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"; done

# ---- icon: the committed Resources/AppIcon.icns is copied as it is. It is NOT regenerated because make-icon.swift looks newer
# (after a git checkout the file times are arbitrary: that rewrote the committed file, took ~3 s and failed on a read-only tree).
# It is drawn into the bundle only when the file is missing; --regen-icon refreshes the committed file on purpose.
ICON_SRC="$ROOT/Resources/make-icon.swift"
ICON="$ROOT/Resources/AppIcon.icns"
draw_icon() {   # draw_icon <output.icns>
  local tmp; tmp="$(mktemp -d "${TMPDIR:-/tmp}/luftig-icon.XXXXXX")"
  swift "$ICON_SRC" "$tmp/AppIcon.iconset" >/dev/null && iconutil -c icns "$tmp/AppIcon.iconset" -o "$1"
  local rc=$?; rm -rf "${tmp:?}"; return $rc
}
if [ "$REGEN_ICON" = 1 ]; then
  [ -f "$ICON_SRC" ] || die "Resources/make-icon.swift not found"
  echo "==> drawing the icon -> $ICON"
  draw_icon "$ICON" || die "icon generation failed"
fi
if [ -f "$ICON" ]; then
  cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
elif [ -f "$ICON_SRC" ]; then
  echo "==> Resources/AppIcon.icns is missing: drawing it into the bundle"
  draw_icon "$APP/Contents/Resources/AppIcon.icns" || die "icon generation failed"
else
  echo "warning: no icon (Resources/AppIcon.icns and Resources/make-icon.swift are missing)" >&2
fi

# ---- sign (ad hoc: no identity needed; the signature changes with every build)
if [ "$SIGN" = 1 ]; then
  echo "==> codesign (ad hoc)"
  codesign --force --deep --sign - --timestamp=none "$APP" 2>&1 | sed 's/^/    /'
fi

# ---- Launch Services: the built bundle is a build product, not an installed app. Once Launch Services knows it, the Finder's "Open With" lists
# every copy of the same name with its version after it ("luftig (1.0.0)") to tell them apart. Spotlight registers every app bundle it indexes,
# so the build folder is named `build.noindex` (a folder Spotlight skips); unregistering the output here covers a bundle that was seen before
# (an `open build.noindex/luftig.app` registers it again until the next build).
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [ -x "$LSREGISTER" ]; then "$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true; fi

# ---- verify
echo "==> verify"
plutil -lint "$APP/Contents/Info.plist" | sed 's/^/    /'
if [ "$SIGN" = 1 ]; then
  codesign --verify --deep --strict "$APP" && echo "    codesign --verify: OK (ad hoc)"
fi
[ -x "$APP/Contents/MacOS/$EXE_NAME" ] || die "executable missing in bundle"
# The look on macOS 26 and later is decided by the SDK version the executable is stamped with (LC_BUILD_VERSION). Package.swift re-stamps it:
# minos stays the deployment target (what Info.plist promises), the SDK version becomes 27.0, so newer systems draw the current design instead of the
# classic chrome. minos must be what Info.plist says (a higher one makes dyld refuse the app on the systems it claims to support).
STAMP="$(otool -l "$APP/Contents/MacOS/$EXE_NAME" 2>/dev/null | awk '/cmd LC_BUILD_VERSION/ {f=1} f && $1=="minos" {m=$2} f && $1=="sdk" {print m, $2; exit}')"
if [ -n "$STAMP" ]; then
  STAMP_MINOS="${STAMP% *}"; STAMP_SDK="${STAMP#* }"
  PLIST_MIN="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist" 2>/dev/null || true)"
  echo "    executable stamp: minos $STAMP_MINOS, SDK $STAMP_SDK (Info.plist LSMinimumSystemVersion ${PLIST_MIN:-not set})"
  if [ -n "$PLIST_MIN" ] && [ "$PLIST_MIN" != "$STAMP_MINOS" ] && [ "$PLIST_MIN.0" != "$STAMP_MINOS" ]; then
    die "the executable's deployment target (minos $STAMP_MINOS) differs from LSMinimumSystemVersion ($PLIST_MIN) in Info.plist"
  fi
  if [ "${STAMP_SDK%%.*}" -lt 26 ] 2>/dev/null; then
    echo "    NOTE: the executable is stamped SDK $STAMP_SDK: macOS 26 and later draw it with the classic window chrome, scrollers and buttons (Package.swift, linkerSettings, re-stamps it)" >&2
  fi
  SDK_IN_USE="$(xcrun --show-sdk-version 2>/dev/null || true)"
  if [ -n "$SDK_IN_USE" ] && [ "$(printf '%s\n%s\n' "$STAMP_SDK" "$SDK_IN_USE" | sort -V | tail -1)" != "$SDK_IN_USE" ]; then
    echo "    NOTE: the executable is stamped SDK $STAMP_SDK but the SDK in use is $SDK_IN_USE: lower the stamp in Package.swift (linkerSettings) to the SDK you build with" >&2
  fi
else
  echo "    note: no LC_BUILD_VERSION found in the executable (the look on macOS 26 and later was not checked)"
fi
# every NSDocumentClass must exist in the binary as a Swift class: "Module.Class" -> _TtC<len>Module<len>Class
for cls in $(/usr/bin/plutil -extract CFBundleDocumentTypes json -o - "$APP/Contents/Info.plist" 2>/dev/null | tr ',' '\n' | sed -n 's/.*"NSDocumentClass" *: *"\([^"]*\)".*/\1/p' | sort -u); do
  mod="${cls%%.*}"; name="${cls#*.}"
  mangled="_TtC${#mod}${mod}${#name}${name}"
  if grep -aqF "$mangled" "$APP/Contents/MacOS/$EXE_NAME"; then
    echo "    NSDocumentClass $cls: present in binary"
  else
    echo "    warning: NSDocumentClass '$cls' ($mangled) not found in the binary - the Open command would fail at runtime" >&2
  fi
done
echo "==> done: $APP"
