#!/bin/bash
# Regenerates docs/screenshots/schemes/: the showcase rendered with EVERY colour scheme (see docs/color-schemes.md), plus two contact sheets.
#
#   Scripts/build-app.sh --selftest --out /tmp/luftig-st
#   ST=/tmp/luftig-st/luftig-SelfTest.app/Contents/MacOS/luftig-SelfTest docs/screenshots/schemes/regenerate.sh
#
# <id>.png       the showcase from "## Lists" on (lists, tasks, quotes with a nested quote, code and a heading inside a quote), with an active selection across
#                a quote and the code block in it
# The showcase from "## Code" on (code blocks, tables) is rendered for every scheme too, but only into contact-sheet-code.png (the single images would double
# the size of this folder).
# A fixed scheme forces the light or dark appearance of the app, so one image per scheme; the default scheme "luftig" follows the system appearance and is
# rendered in both (luftig.png = light, luftig-dark.png). Nothing is shown on screen: the editor window is rendered offscreen.
# The contact sheets (contact-sheet.png, contact-sheet-code.png) are made with contact-sheet.swift (CoreGraphics; compiled into a temporary directory).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
ST="${ST:?set ST to the luftig-SelfTest executable}"
OUT="$ROOT/docs/screenshots/schemes"
SHOW="$ROOT/docs/showcase.md"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# id|name of every scheme (ColorSchemes.all; the `schemes-roles` self-test checks that the list is complete)
IDS="luftig|luftig
solarized-light|Solarized Light
solarized-dark|Solarized Dark
github-light|GitHub Light
github-dark|GitHub Dark
one-light|One Light
one-dark|One Dark
gruvbox-light|Gruvbox Light
gruvbox-dark|Gruvbox Dark
dracula|Dracula
nord|Nord
monokai|Monokai
tomorrow-night|Tomorrow Night
catppuccin-latte|Catppuccin Latte
catppuccin-mocha|Catppuccin Mocha
tokyo-night|Tokyo Night"
n=0
shot() {   # shot <out> <args...>
  local out="$1"; shift; n=$((n+1))
  "$ST" --selftest render --input "$SHOW" --out "$out" --workdir="$WORK/w$n" "$@" | grep -E "FAIL" || true
}
mkdir -p "$WORK/code"
LABELS=(); LABELS_CODE=()
while IFS='|' read -r id name; do
  [ -z "$id" ] && continue
  if [ "$id" = "luftig" ]; then
    shot "$OUT/luftig.png"           --scheme luftig --appearance light --scroll-to-text "## Lists" --height 1300 --select-text "a quote may span:let quoted" --active-selection
    shot "$WORK/code/luftig-code.png"      --scheme luftig --appearance light --scroll-to-text "## Code" --height 1100
    shot "$OUT/luftig-dark.png"      --scheme luftig --appearance dark --scroll-to-text "## Lists" --height 1300 --select-text "a quote may span:let quoted" --active-selection
    shot "$WORK/code/luftig-dark-code.png" --scheme luftig --appearance dark --scroll-to-text "## Code" --height 1100
    LABELS+=("luftig (light)=$OUT/luftig.png" "luftig (dark)=$OUT/luftig-dark.png"); LABELS_CODE+=("luftig (light)=$WORK/code/luftig-code.png" "luftig (dark)=$WORK/code/luftig-dark-code.png")
  else
    shot "$OUT/$id.png"      --scheme "$id" --scroll-to-text "## Lists" --height 1300 --select-text "a quote may span:let quoted" --active-selection
    shot "$WORK/code/$id-code.png" --scheme "$id" --scroll-to-text "## Code" --height 1100
    LABELS+=("$name=$OUT/$id.png"); LABELS_CODE+=("$name=$WORK/code/$id-code.png")
  fi
done <<< "$IDS"

mkdir -p "$WORK/cs"
swiftc -O "$OUT/contact-sheet.swift" -o "$WORK/cs/contact-sheet"
"$WORK/cs/contact-sheet" "$OUT/contact-sheet.png" 4 "${LABELS[@]}"
"$WORK/cs/contact-sheet" "$OUT/contact-sheet-code.png" 4 "${LABELS_CODE[@]}"
