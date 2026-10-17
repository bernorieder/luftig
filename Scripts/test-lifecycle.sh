#!/bin/bash
#
# test-lifecycle.sh - black-box tests of the app's launch / reopen / quit / restoration behaviour with the REAL AppDelegate.
#
#   Scripts/build-app.sh --selftest              # once: build/luftig-SelfTest.app
#   bash Scripts/test-lifecycle.sh [luftig-SelfTest.app]     exit status 0: all checks passed       (about 1 minute)
#
# The in-process runner (`luftig-SelfTest --selftest ...`) has its own application delegate, so it cannot see what AppDelegate does
# at launch, on a Dock click or after window restoration. This script launches the self-test bundle through Launch Services the way
# Finder does (open -g -j: background, hidden; a helper keeps the app hidden, so no window ever reaches the screen and nothing is
# activated), drives it through the command channel of SelfTest/SelfTestHooks.swift (-LuftigCommands: report, new-doc, type,
# close-windows, press, quit) and checks what the user would see: the number of documents and editor windows, alerts, file contents.
#
# Safety: it works on a COPY of the bundle with its own bundle identifier (preferences, Open Recent and saved window state of the
# real app and of other test bundles are never touched), only regular files in a scratch directory are used, the copy is
# unregistered from Launch Services and everything is removed at the end, also on Ctrl-C.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:-$HERE/build/luftig-SelfTest.app}"
[ -d "$SRC/Contents/MacOS" ] || { echo "no self-test bundle at: $SRC   (build it: Scripts/build-app.sh --selftest)"; exit 2; }
command -v swiftc >/dev/null || { echo "swiftc not found (Command Line Tools)"; exit 2; }
PB=/usr/libexec/PlistBuddy
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/luftig-lifecycle.XXXXXX")"
T="$TMP_ROOT/Lifecycle Ünï"; mkdir -p "$T"
APP="$T/luftig Lifecycle.app"
CMD="$T/commands.txt"; REP="$T/report.json"; WORK="$T/files"; mkdir -p "$WORK"
BUNDLE_ID=""; PID=""; HIDER=""
# Launch Services hands the app the file-system's (decomposed) spelling of a path with accents, so processes are found by an
# ASCII marker argument, never by the path ("Ünï" in the pattern does not match "U" + combining diaeresis in the process).
MARK="LuftigLifecycleRun $$"

cleanup() {
  [ -n "$HIDER" ] && kill "$HIDER" 2>/dev/null
  pkill -9 -f "Contents/MacOS/.* -$MARK" 2>/dev/null
  [ -d "$APP" ] && "$LSREGISTER" -u "$APP" >/dev/null 2>&1
  [ -n "$BUNDLE_ID" ] && defaults delete "$BUNDLE_ID" >/dev/null 2>&1
  chmod -R u+w "${TMP_ROOT:?}" 2>/dev/null; rm -rf "${TMP_ROOT:?}"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); echo "  ok    $1"; }
bad()   { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1   [$2]"; fi; }

# ---- a private copy of the bundle: own identity, never a default handler (the self-test build already ranks both types Alternate)
cp -R "$SRC" "$APP"
P="$APP/Contents/Info.plist"
OLD_ID="$($PB -c 'Print :CFBundleIdentifier' "$P")"
BUNDLE_ID="$OLD_ID.lifecycle"
$PB -c "Set :CFBundleIdentifier $BUNDLE_ID" "$P"
codesign --force --deep --sign - --timestamp=none "$APP" >/dev/null 2>&1 || { echo "cannot sign the bundle copy"; exit 2; }
EXE="$(ls "$APP/Contents/MacOS" | head -1)"
grep -aqi selftest "$APP/Contents/MacOS/$EXE" || { echo "$SRC is not a self-test build (no -LuftigCommands channel): Scripts/build-app.sh --selftest"; exit 2; }

# ---- the helper that keeps the launched app hidden (a hidden launch still orders a document window front for a moment)
cat > "$T/hide.swift" <<'EOF'
import AppKit
let pid = pid_t(CommandLine.arguments[1])!
while let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated {
    app.hide()
    RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
}
EOF
swiftc -O "$T/hide.swift" -o "$T/hide" >/dev/null 2>&1 || { echo "cannot compile the hide helper"; exit 2; }

cat > "$T/report.py" <<'PY'
import json, sys, shlex
try: r = json.load(open(sys.argv[1]))
except Exception: r = None
if r is None:
    print("WINMENU="); print("DOCS=-1 EDWIN=-1 NAMES= LENS= EDITED= ALERTS="); sys.exit()
docs = r["documents"]
ed = [w for w in r["windows"] if w["class"] == "NSWindow" and not w["isSheet"]]
alerts = [" / ".join(w["texts"]) for w in r["windows"] if w.get("texts")]
print("WINMENU=%s" % shlex.quote("|".join(r.get("windowMenuTitles", []))))
print("DOCS=%d EDWIN=%d NAMES=%s LENS=%s EDITED=%s ALERTS=%s" % (len(docs), len(ed),
      shlex.quote("|".join(d["displayName"] for d in docs)), shlex.quote(" ".join(str(d.get("textLength", "")) for d in docs)),
      shlex.quote(" ".join("1" if d["edited"] else "0" for d in docs)), shlex.quote(" || ".join(alerts))))
PY

# ---- driver
start() {        # start [file...] -- [app args...]      -> PID, hidden launch
  local files=() args=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do files+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift; args=("$@")
  rm -f "$CMD" "$REP"
  open -g -j -n -a "$APP" "${files[@]+"${files[@]}"}" --args -LuftigCommands "$CMD" -$MARK "${args[@]+"${args[@]}"}"
  PID=""
  for _ in $(seq 1 100); do PID="$(pgrep -f "Contents/MacOS/.* -$MARK" | head -1)"; [ -n "$PID" ] && break; sleep 0.05; done
  [ -n "$PID" ] || { bad "the app did not start"; return 1; }
  "$T/hide" "$PID" & HIDER=$!
  sleep 0.7
}
cmd()    { echo "$1" >> "$CMD"; }
report() {       # report  -> WINMENU DOCS EDWIN NAMES LENS EDITED ALERTS (shell variables)
  rm -f "$REP"; cmd "report $REP"
  for _ in $(seq 1 100); do [ -s "$REP" ] && break; sleep 0.05; done
  eval "$(/usr/bin/python3 -I "$T/report.py" "$REP")"
}
quit_app() {     # quit through the application's own terminate path; fail if it does not end
  cmd quit
  for _ in $(seq 1 100); do kill -0 "$PID" 2>/dev/null || break; sleep 0.05; done
  if kill -0 "$PID" 2>/dev/null; then bad "the app did not quit within 5 s"; kill -9 "$PID" 2>/dev/null; fi
  [ -n "$HIDER" ] && { kill "$HIDER" 2>/dev/null; wait "$HIDER" 2>/dev/null; HIDER=""; }
  sleep 0.2
}
reset_state() {  # saved window state of the copy: restore whatever is saved, close every window, quit -> "no windows" is saved
  start -- ; cmd close-windows; sleep 0.5; quit_app
}
newfile() { printf '%s' "$2" > "$WORK/$1"; echo "$WORK/$1"; }

echo "== lifecycle (self-test bundle copy: $BUNDLE_ID)"
reset_state

# -- plain launch, Dock click (reopen), closing the last window
start -- -ApplePersistenceIgnoreState YES; report
check "plain launch: ONE untitled document with ONE window (docs $DOCS, windows $EDWIN, '$NAMES')" '[ "$DOCS" = 1 ] && [ "$EDWIN" = 1 ] && [ "$NAMES" = Untitled ]'
open -g -a "$APP"; sleep 0.8; report
check "Dock click (reopen) while a window exists: nothing new (docs $DOCS, windows $EDWIN)" '[ "$DOCS" = 1 ] && [ "$EDWIN" = 1 ]'
cmd close-windows; sleep 0.5; report
check "closing the last window leaves the app running with no document (docs $DOCS, windows $EDWIN)" 'kill -0 $PID 2>/dev/null && [ "$DOCS" = 0 ] && [ "$EDWIN" = 0 ]'
open -g -a "$APP"; sleep 1.0; report
check "Dock click with no window: a new untitled document (docs $DOCS, windows $EDWIN)" '[ "$DOCS" = 1 ] && [ "$EDWIN" = 1 ] && [ "$NAMES" = Untitled ]'
quit_app
check "after quit no process of the app is left" '! pgrep -f "Contents/MacOS/.* -$MARK" >/dev/null'

# -- launches that open files (no untitled document next to them)
A="$(newfile a.md '# A')"; B="$(newfile b.md 'bee')"; U="$(newfile 'Ünï cödé 😀 file.md' 'unicode name')"; E="$(newfile empty.md '')"
start "$A" -- -ApplePersistenceIgnoreState YES; sleep 0.8; report
check "launch with one file: that document only (docs $DOCS, windows $EDWIN, '$NAMES')" '[ "$DOCS" = 1 ] && [ "$EDWIN" = 1 ] && [ "$NAMES" = a.md ]'
open -g -a "$APP" "$A"; sleep 0.8; report
check "the same file opened again while running: still one window (docs $DOCS, windows $EDWIN)" '[ "$DOCS" = 1 ] && [ "$EDWIN" = 1 ]'
open -g -a "$APP" "$B"; sleep 0.8; report
check "a second file while running: two documents, two windows (docs $DOCS, windows $EDWIN)" '[ "$DOCS" = 2 ] && [ "$EDWIN" = 2 ]'
quit_app
start "$A" "$B" -- -ApplePersistenceIgnoreState YES; sleep 0.8; report
check "launch with two files: two documents, two windows (docs $DOCS, windows $EDWIN)" '[ "$DOCS" = 2 ] && [ "$EDWIN" = 2 ]'
check "... and the Window menu lists both documents (items: $WINMENU)" '[[ "$WINMENU" == *a.md* ]] && [[ "$WINMENU" == *b.md* ]]'
quit_app
start "$A" "$A" -- -ApplePersistenceIgnoreState YES; sleep 0.8; report
check "the same file twice in one launch: one document (docs $DOCS, windows $EDWIN)" '[ "$DOCS" = 1 ] && [ "$EDWIN" = 1 ]'
quit_app
start "$U" -- -ApplePersistenceIgnoreState YES; sleep 0.8; report
check "file name with spaces, accents and an emoji: opens ('$NAMES', docs $DOCS)" '[ "$DOCS" = 1 ] && [ "$EDWIN" = 1 ] && [ "$LENS" = 12 ]'
quit_app
start "$E" -- -ApplePersistenceIgnoreState YES; sleep 0.8; report
check "0-byte file: opens, empty (docs $DOCS, length '$LENS')" '[ "$DOCS" = 1 ] && [ "$LENS" = 0 ]'
quit_app

# -- an edit is never lost by quitting right away (the autosave delay is 3 s)
Q="$(newfile quit.md 'original')"
start "$Q" -- -ApplePersistenceIgnoreState YES; cmd 'type QUIT '; sleep 0.4; report
check "typed into a saved file: the document is marked edited" '[ "$EDITED" = 1 ]'
quit_app
check "quit right after typing: the edit is in the file ($(cat "$Q"))" '[ "$(cat "$Q")" = "QUIT original" ]'

# -- window restoration
reset_state       # (closes every window and quits: the saved state is "no windows")
start; sleep 1.2; report
check "closing every window, quitting and launching again: ONE untitled document, not an app without a window (docs $DOCS, windows $EDWIN)" '[ "$DOCS" = 1 ] && [ "$EDWIN" = 1 ] && [ "$NAMES" = Untitled ]'
quit_app
reset_state
R1="$(newfile r1.md 'one')"; R2="$(newfile r2.md 'two')"
start "$R1" "$R2"; sleep 0.8; quit_app
start; sleep 1.2; report
check "relaunch restores both windows and adds no untitled one (docs $DOCS, windows $EDWIN, '$NAMES')" '[ "$DOCS" = 2 ] && [ "$EDWIN" = 2 ] && [[ "$NAMES" != *Untitled* ]]'
quit_app
rm -f "$R1"
start; sleep 1.2; report
check "one of the two files deleted meanwhile: the other is restored, silently (docs $DOCS, '$NAMES', alerts '$ALERTS')" '[ "$DOCS" = 1 ] && [ "$NAMES" = r2.md ] && [ -z "$ALERTS" ]'
quit_app
rm -f "$R2"
start; sleep 1.5; report
check "EVERY restorable file deleted: the app still opens ONE untitled document, not nothing (docs $DOCS, windows $EDWIN)" '[ "$DOCS" = 1 ] && [ "$EDWIN" = 1 ] && [ "$NAMES" = Untitled ]'
quit_app
reset_state
DRAFT='a draft that was never saved'
start; cmd "type $DRAFT"; sleep 4.5; quit_app
start; sleep 1.2; report
check "an untitled draft typed before quitting comes back with its text (docs $DOCS, length '$LENS', edited '$EDITED')" '[ "$DOCS" = 1 ] && [ "$NAMES" = Untitled ] && [ "$LENS" = ${#DRAFT} ]'
cmd close-windows; sleep 0.4; quit_app

# -- a read-only file: the lock sheet, Cancel undoes the keystroke, nothing is written
RO="$(newfile ro.md 'locked')"; chmod 444 "$RO"
start "$RO" -- -ApplePersistenceIgnoreState YES; cmd 'type EDIT '; sleep 0.8; report
check "typing into a read-only file raises the 'locked' sheet (alerts: ${ALERTS:0:60}...)" '[[ "$ALERTS" == *locked* ]]'
cmd 'press Cancel'; sleep 0.8; report
check "answering Cancel takes the keystroke back and writes nothing (length '$LENS', file '$(cat "$RO")')" '[ "$LENS" = 6 ] && [ "$(cat "$RO")" = locked ]'
quit_app

echo
echo "lifecycle tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
