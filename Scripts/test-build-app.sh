#!/bin/bash
#
# test-build-app.sh - tests of Scripts/build-app.sh itself, in a few seconds and without compiling luftig.
#
#   bash Scripts/test-build-app.sh       exit status 0: all checks passed
#
# The script is copied into a scratch directory (a path with spaces, a non-ASCII character, quotes, $ and &), a stub `swift` first in PATH
# plays "swift build" and "swift make-icon.swift", and tiny C programs play the built executable. What is checked:
#   * the committed icon is used as it is: a make-icon.swift that is NEWER than AppIcon.icns (every fresh git checkout!) neither
#     runs the generator nor touches the source tree; a missing icon is drawn into the bundle only; --regen-icon refreshes the file
#   * the "no test code in the shipping binary" guard really fails - for 'selftest' strings and for the other hook strings (20 runs
#     each: the old `strings | grep -q` form lost the match to SIGPIPE under pipefail now and then) - and the self-test variant must
#     contain its hooks
#   * the executable's stamp (LC_BUILD_VERSION) is checked: minos must equal LSMinimumSystemVersion (a different one is refused), an SDK stamp below 26
#     (macOS 26+ then draws the classic look) or above the SDK in use is reported, the normal stamp (minos 14.0, SDK >= 26) is reported without a note
#   * --out "" and --out <directory that is not an app bundle> are refused before anything is deleted
#   * --help, unknown arguments, a second run over an existing bundle, relative --out, running from another working directory

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/luftig-build-test.XXXXXX")"
T="$TMP_ROOT/Test Ünï 'q' \$x & (y)"
mkdir -p "$T"
trap 'chmod -R u+w "${TMP_ROOT:?}" 2>/dev/null; rm -rf "${TMP_ROOT:?}"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok    $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1   [$2]"; fi; }

command -v clang >/dev/null || { echo "clang not found (Command Line Tools)"; exit 2; }

# ---- the world: a copy of the repo pieces the script needs, stub tools, fake executables
REPO="$T/repo"; STUB="$T/stub"; FAKE="$T/fake"; mkdir -p "$REPO" "$STUB" "$FAKE"
cp -R "$HERE/Scripts" "$HERE/Resources" "$REPO/"
cp "$HERE/Package.swift" "$REPO/" 2>/dev/null || true

# (the fakes carry the stamp the real executable has: minos 14.0, SDK = the one in use; `classic` / `old13` / `newer` are the stamps the checks must notice)
compile() { printf '%s\n' "$2" | clang -x c - -mmacosx-version-min=14.0 ${3:-} -o "$FAKE/$1" 2>/dev/null || { echo "cannot compile the fake executable $1"; exit 2; }; }
compile plain      '#include <stdio.h>
int main(void){ puts("hello"); return 0; }'
compile selftest   '#include <stdio.h>
int main(void){ puts("luftig-SelfTest"); return 0; }'
compile probe      '#include <stdio.h>
int main(void){ puts("LuftigLaunchProbe"); return 0; }'
compile report     '#include <stdio.h>
int main(void){ puts("LuftigReport"); return 0; }'
compile commands   '#include <stdio.h>
int main(void){ puts("LuftigCommands"); return 0; }'
compile classic    '#include <stdio.h>
int main(void){ puts("hello"); return 0; }' '-Wl,-platform_version,macos,14.0,14.0'
compile old13      '#include <stdio.h>
int main(void){ puts("hello"); return 0; }' '-mmacosx-version-min=13.0'
compile newer      '#include <stdio.h>
int main(void){ puts("hello"); return 0; }' '-Wl,-platform_version,macos,14.0,99.0'
# a bigger one: the marker sits in front of ~200 KB of other strings (what makes `strings | grep -q` race)
{ printf '#include <stdio.h>\nconst char *a = "LuftigLaunchProbe";\n'; for i in $(seq 1 4000); do printf 'const char *s%d = "filler string number %d to make the output of strings long";\n' $i $i; done
  printf 'int main(void){ puts(a);'; for i in $(seq 1 4000); do printf ' puts(s%d);' $i; done; printf ' return 0; }\n'; } > "$FAKE/big.c"
clang -O0 -mmacosx-version-min=14.0 "$FAKE/big.c" -o "$FAKE/bigprobe" 2>/dev/null || { echo "cannot compile bigprobe"; exit 2; }

# the committed icon as an iconset: what the stub "swift make-icon.swift" writes
iconutil -c iconset "$REPO/Resources/AppIcon.icns" -o "$FAKE/stub.iconset" >/dev/null 2>&1 || { echo "iconutil failed"; exit 2; }

cat > "$STUB/swift" <<'EOF'
#!/bin/bash
# stub: `swift build ... [--show-bin-path]` and `swift <script.swift> <out.iconset>`
if [ "$1" = build ]; then
  if [[ " $* " == *" --show-bin-path "* ]]; then echo "$FAKE_BIN_DIR"; exit 0; fi
  mkdir -p "$FAKE_BIN_DIR"; cp "$FAKE_EXE" "$FAKE_BIN_DIR/luftig"; echo "Build complete! (0.01s)"; exit 0
fi
echo "$*" >> "$FAKE_LOG"
mkdir -p "$2"; cp "$FAKE_ICONSET"/*.png "$2/"
EOF
chmod +x "$STUB/swift"
# stub xcrun: the SDK version "in use" (build-app.sh compares it with the stamp)
cat > "$STUB/xcrun" <<'XEOF'
#!/bin/bash
[ "$1" = --show-sdk-version ] && { echo "${FAKE_SDK:-27.0}"; exit 0; }
exit 1
XEOF
chmod +x "$STUB/xcrun"
export PATH="$STUB:$PATH" FAKE_BIN_DIR="$T/bin" FAKE_LOG="$T/swift-calls.log" FAKE_ICONSET="$FAKE/stub.iconset"

build() {   # build <fake exe> [script args...]   -> runs from another cwd; $T/last.log has the output
  export FAKE_EXE="$FAKE/$1"; shift
  ( cd "$T" && "$REPO/Scripts/build-app.sh" --no-sign "$@" ) > "$T/last.log" 2>&1
}
icns_sum() { shasum "$1" | awk '{print $1}'; }

echo "== build-app.sh"
# -- a normal build from another working directory, relative --out, then a second run over the existing bundle
: > "$FAKE_LOG"
build plain --out out1; rc=$?
check "normal build succeeds (from another cwd, --out relative): exit $rc" '[ $rc = 0 ] && [ -x "$T/out1/luftig.app/Contents/MacOS/luftig" ]'
check "the bundle has Info.plist, PkgInfo, icon" '[ -f "$T/out1/luftig.app/Contents/Info.plist" ] && [ -f "$T/out1/luftig.app/Contents/PkgInfo" ] && [ -f "$T/out1/luftig.app/Contents/Resources/AppIcon.icns" ]'
# the shipping plist must export no UTI and never rank a document type Default/Owner: an exported type for .mkd & co. once made
# luftig (and its self-test build) the default app for those files system-wide, taking them from the user's own editor; and with
# EQUAL ranks Launch Services picks the app that ran most recently, so the extension-only type must be rank None
shipping_plist_ok() {
  local P="$1" n=0 r exts
  /usr/libexec/PlistBuddy -c 'Print :UTExportedTypeDeclarations' "$P" >/dev/null 2>&1 && return 1
  while r="$(/usr/libexec/PlistBuddy -c "Print :CFBundleDocumentTypes:$n:LSHandlerRank" "$P" 2>/dev/null)"; do
    case "$r" in Alternate|None) ;; *) return 1 ;; esac
    if /usr/libexec/PlistBuddy -c "Print :CFBundleDocumentTypes:$n:CFBundleTypeExtensions" "$P" >/dev/null 2>&1; then [ "$r" = None ] || return 1; fi
    n=$((n+1))
  done
  [ "$n" -gt 0 ]
}
check "the shipping Info.plist exports no UTI, no document type is rank Default/Owner, the extension-only type is rank None" 'shipping_plist_ok "$T/out1/luftig.app/Contents/Info.plist"'
build plain --out out1; rc=$?
check "a second run over the existing bundle succeeds: exit $rc" '[ $rc = 0 ]'

# -- the look: the executable's stamp (Package.swift re-stamps it: minos = the deployment target, SDK >= 26)
check "the normal stamp (minos 14.0, SDK 27.0) is reported and raises no note" 'grep -q "executable stamp: minos 14.0, SDK 27.0 (Info.plist LSMinimumSystemVersion 14.0)" "$T/last.log" && ! grep -q "NOTE" "$T/last.log"'
build classic --out stamp1; rc=$?
check "a build stamped SDK 14.0 succeeds but says that macOS 26+ draws the classic look (exit $rc)" '[ $rc = 0 ] && grep -q "stamped SDK 14.0: macOS 26 and later draw it with the classic" "$T/last.log"'
build old13 --out stamp2; rc=$?
check "an executable whose minos (13.0) differs from LSMinimumSystemVersion (14.0) is refused (exit $rc)" '[ $rc != 0 ] && grep -q "differs from LSMinimumSystemVersion" "$T/last.log"'
build newer --out stamp3; rc=$?
check "a stamp newer than the SDK in use (99.0 vs 27.0) is reported (exit $rc)" '[ $rc = 0 ] && grep -q "stamped SDK 99.0 but the SDK in use is 27.0" "$T/last.log"'
FAKE_SDK=26.5 build plain --out stamp4; rc=$?
check "SDK 27.0 stamped on a machine whose SDK is 26.5 is reported (exit $rc)" '[ $rc = 0 ] && grep -q "stamped SDK 27.0 but the SDK in use is 26.5" "$T/last.log"'

# -- the icon
ICON_SUM="$(icns_sum "$REPO/Resources/AppIcon.icns")"
sleep 1; touch "$REPO/Resources/make-icon.swift"          # NEWER than AppIcon.icns: what a fresh git checkout may look like
: > "$FAKE_LOG"
build plain --out out2; rc=$?
check "make-icon.swift newer than AppIcon.icns: build succeeds (exit $rc)" '[ $rc = 0 ]'
check "... the icon generator is NOT run ($(wc -l < "$FAKE_LOG" | tr -d ' ') call(s))" '[ ! -s "$FAKE_LOG" ]'
check "... the committed Resources/AppIcon.icns is byte-identical afterwards" '[ "$(icns_sum "$REPO/Resources/AppIcon.icns")" = "$ICON_SUM" ]'
check "... and is what the bundle contains" '[ "$(icns_sum "$T/out2/luftig.app/Contents/Resources/AppIcon.icns")" = "$ICON_SUM" ]'
chmod -R a-w "$REPO/Resources"
build plain --out out3; rc=$?
check "read-only Resources/ (a packaged source tree): build succeeds (exit $rc)" '[ $rc = 0 ]'
chmod -R u+w "$REPO/Resources"
mv "$REPO/Resources/AppIcon.icns" "$T/AppIcon.keep"
: > "$FAKE_LOG"
build plain --out out4; rc=$?
check "AppIcon.icns missing: the icon is drawn (once) into the bundle: exit $rc, $(wc -l < "$FAKE_LOG" | tr -d ' ') generator call(s)" '[ $rc = 0 ] && [ "$(wc -l < "$FAKE_LOG" | tr -d " ")" = 1 ] && [ -s "$T/out4/luftig.app/Contents/Resources/AppIcon.icns" ]'
check "... and the source tree stays untouched (no AppIcon.icns written into Resources/)" '[ ! -e "$REPO/Resources/AppIcon.icns" ]'
: > "$FAKE_LOG"
build plain --regen-icon --out out5; rc=$?
check "--regen-icon draws the icon into Resources/AppIcon.icns on purpose: exit $rc" '[ $rc = 0 ] && [ -s "$REPO/Resources/AppIcon.icns" ] && [ "$(wc -l < "$FAKE_LOG" | tr -d " ")" = 1 ]'

# -- the guard against test code in the shipping binary
for v in selftest probe report commands bigprobe; do
  fails=0
  for i in $(seq 1 20); do build "$v" --out guard; rc=$?; [ $rc != 0 ] && grep -q "contains self-test code" "$T/last.log" && fails=$((fails+1)); done
  check "shipping binary containing the '$v' marker: the build is refused (20 of 20 runs; $fails refused)" '[ $fails = 20 ]'
done
build plain --selftest --out st; rc=$?
check "the self-test variant must contain its hooks: a binary without them is refused (exit $rc)" '[ $rc != 0 ] && grep -q "does not contain the self-test code" "$T/last.log"'
build selftest --selftest --out st; rc=$?
check "the self-test variant with hooks builds as luftig-SelfTest.app (exit $rc)" '[ $rc = 0 ] && [ -d "$T/st/luftig-SelfTest.app" ] && [ "$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$T/st/luftig-SelfTest.app/Contents/Info.plist")" = "local.luftig.luftig.selftest" ]'

# -- argument handling and what --out may replace
build plain --out ""; rc=$?
check "--out \"\" is refused (exit $rc)" '[ $rc != 0 ] && grep -q "non-empty" "$T/last.log"'
mkdir -p "$T/precious.app/Documents"; : > "$T/precious.app/Documents/keep.txt"
build plain --out "$T/precious.app"; rc=$?
check "--out <existing directory that is not an app bundle> is refused and nothing is deleted (exit $rc)" '[ $rc != 0 ] && [ -f "$T/precious.app/Documents/keep.txt" ]'
build plain --bogus; rc=$?
check "unknown argument: exit 1 with a hint (exit $rc)" '[ $rc = 1 ] && grep -q "unknown argument" "$T/last.log"'
build plain --out; rc=$?
check "--out without a value: exit 1 (exit $rc)" '[ $rc = 1 ]'
build plain --help; rc=$?
check "--help prints the usage and exits 0 (exit $rc)" '[ $rc = 0 ] && grep -q "build-app.sh - assemble" "$T/last.log" && grep -q -- "--regen-icon" "$T/last.log"'

echo
echo "build-app.sh tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
