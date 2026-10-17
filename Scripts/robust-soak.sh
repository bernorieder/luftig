#!/bin/bash
#
# robust-soak.sh - drive the robustness scenarios (Sources/luftig/SelfTest/SelfTestRobust*.swift), ONE PROCESS PER SEED / CASE, so that a
# crash (status 134), a hang (status 3, with a `sample` of the main thread) or a timeout (status 2/142) is attributed to its seed / case.
#
#   Scripts/robust-soak.sh APP monkey FIRST_SEED LAST_SEED [STEPS=2000] [DOCS=3]     # APP = .../luftig-SelfTest.app
#   Scripts/robust-soak.sh APP hostile [case ...]                                    # no case: every heavy case
#   Scripts/robust-soak.sh APP leaks | resource-policy | storm | reader-race | robust-regress [scenario arguments...]
#
# Environment: WORK=<dir> (default: $TMPDIR/robust-soak), LOGS=<dir> (default: $WORK/logs), LIMIT=<seconds per process, default 900>,
#              JOBS=<parallel processes, default 1; never more than 2 on a shared machine>, EXTRA="--any --extra --args"
# Each process writes $LOGS/<mode>-<seed|case>.log; a summary line per process goes to stdout. Exit status 1 if any process failed.

set -u
APP="${1:?usage: robust-soak.sh APP.app monkey|hostile|leaks|resource-policy|storm|reader-race|robust-regress ...}"; MODE="${2:?mode}"; shift 2
BIN="$APP/Contents/MacOS/luftig-SelfTest"
[ -x "$BIN" ] || { echo "no self-test executable at $BIN (build with Scripts/build-app.sh --selftest)"; exit 2; }
WORK="${WORK:-${TMPDIR:-/tmp}/robust-soak}"; LOGS="${LOGS:-$WORK/logs}"; LIMIT="${LIMIT:-900}"; JOBS="${JOBS:-1}"; EXTRA="${EXTRA:-}"
mkdir -p "$LOGS"
FAILED=0

run_one() {   # name, scenario, args...
  local name="$1" scen="$2"; shift 2
  local log="$LOGS/$name.log"
  local t0=$(date +%s)
  # (a hung self-test - a main-thread exception - was seen to ignore SIGALRM for more than 13 minutes: the limit is a SIGKILL)
  "$BIN" --selftest "$scen" --workdir="$WORK/w-$name" --timeout=$((LIMIT - 10)) "$@" $EXTRA > "$log" 2>&1 &
  local pid=$!
  ( exec >/dev/null 2>&1 </dev/null; sleep "$LIMIT"; kill -9 "$pid" 2>/dev/null ) &
  local killer=$!
  wait "$pid"
  local rc=$?
  kill "$killer" 2>/dev/null; wait "$killer" 2>/dev/null
  local dt=$(( $(date +%s) - t0 ))
  local verdict
  case $rc in
    0) verdict="PASS";;
    1) verdict="FAIL (check failed)";;
    2) verdict="TIMEOUT/RUNNER ($(grep -a 'SELFTEST TIMEOUT' "$log" | head -1))";;
    3) verdict="HANG ($(grep -a 'ROBUST-HANG:' "$log" | head -1 | cut -c1-160))";;
    134) verdict="CRASH ($(grep -a 'ROBUST-CRASH' "$log" | head -1 | cut -c1-160))";;
    137|142) verdict="KILLED after ${LIMIT}s";;
    *) verdict="exit $rc";;
  esac
  printf '%-34s %6ss  %s\n' "$name" "$dt" "$verdict"
  [ $rc -eq 0 ] || return 1
}

wait_slot() { while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge "$JOBS" ]; do sleep 0.5; done; }

case "$MODE" in
  monkey)
    FIRST="${1:?first seed}"; LAST="${2:?last seed}"; STEPS="${3:-2000}"; DOCS="${4:-3}"
    for seed in $(seq "$FIRST" "$LAST"); do
      wait_slot
      ( run_one "monkey-$seed" monkey --seed "$seed" --steps "$STEPS" --docs "$DOCS" --log "$LOGS/monkey-$seed.actions.jsonl" ) &
    done
    ;;
  hostile)
    if [ $# -eq 0 ]; then
      set -- $("$BIN" --selftest hostile --cases list 2>&- | awk '/note/ && !/\[smoke\]/ {print $2}')
    fi
    for c in "$@"; do
      wait_slot
      ( run_one "hostile-$c" hostile --cases "$c" ) &
    done
    ;;
  leaks|resource-policy|storm|reader-race|robust-regress)
    run_one "$MODE" "$MODE" "$@" || FAILED=1
    ;;
  *) echo "unknown mode $MODE"; exit 2;;
esac
wait
# summary of failures
if ls "$LOGS"/*.log >&- 2>&-; then
  grep -al 'FAIL \|ROBUST-HANG\|ROBUST-CRASH\|SELFTEST TIMEOUT' "$LOGS"/*.log 2>&- | sed 's#.*/##' | tr '\n' ' ' | sed 's/^/failing logs: /'; echo
fi
rm -rf "$WORK"/w-*
