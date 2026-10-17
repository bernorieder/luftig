#!/bin/bash
# Regenerates the screenshots in this folder from docs/showcase.md with the self-test build (see README.md, "Tests"):
#
#   Scripts/build-app.sh --selftest --out /tmp/luftig-st
#   ST=/tmp/luftig-st/luftig-SelfTest.app/Contents/MacOS/luftig-SelfTest docs/screenshots/regenerate.sh
#
# Every page starts at a heading of the showcase (--scroll-to-text). Nothing is shown on screen: the editor window is rendered offscreen.
# Set BEFORE=/path/to/older/luftig-SelfTest to render the `before/` set with another build (same document, same options).
# Set CLASSIC=/path/to/luftig-SelfTest, a self-test build WITHOUT the re-stamp (Package.swift without its `linkerSettings`: SDK stamp 14.0), to refresh
# `classic-look/`: the screens as macOS 26 and later drew them before the app was re-stamped (classic window chrome, bordered banner buttons, classic controls
# in the Settings window). Only the renders that differ are kept: the conflict banner, the Settings window and one editor page (02-emphasis-links-light:
# the classic scroller knob at the right edge, which the current look's offscreen render does not draw). Every other editor render is pixel-identical between
# the two looks; the title bar, tab bar and full-screen chrome are outside the content view and are in neither set.
#
# Two images are montages made from these renders with a small image tool (not in the repository):
#   14-colour-blind-light.png  the Emphasis page (02) through the deuteranopia / protanopia / tritanopia matrices of Machado et al. 2009
#                              (normal | deuteranopia | protanopia | tritanopia), applied in linear RGB
#   15-font-sizes-light.png    the quotes page at --font-size 11 / 13 / 20 / 28, side by side
# 19-settings-*: the Settings window at the user's configuration (GitHub Dark, Fira Code, 14 pt) with the line-spacing note shown and hidden, made with
#   "$ST" --selftest fix-settings-layout --png-prefix=docs/screenshots/19-settings-after   (and settings-render for 19-settings-after-default-light);
#   the 19-settings-before-* pair is the build before the fixes (classic look): the controls jumped when the note came and went. Not made by this script.
# `before/` holds the first-pass look (docs rendered with the unchanged code); its 08-selection images show the INACTIVE (grey, opaque) selection, because
# the first pass had no way to paint the active selection in an offscreen window.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ST="${ST:?set ST to the luftig-SelfTest executable}"
OUT="$ROOT/docs/screenshots"
SHOW="$ROOT/docs/showcase.md"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

shot() {   # shot <binary> <out> <args...>
  local bin="$1" out="$2"; shift 2
  "$bin" --selftest render --input "$SHOW" --out "$out" --workdir="$WORK/w" "$@" | grep -E "FAIL|rendered" | sed 's/(.*KB/(KB/'
}

for a in light dark; do
  shot "$ST" "$OUT/01-top-$a.png"                --appearance $a
  shot "$ST" "$OUT/02-emphasis-links-$a.png"     --appearance $a --scroll-to-text "## Emphasis and friends"
  shot "$ST" "$OUT/03-lists-tasks-$a.png"        --appearance $a --scroll-to-text "## Lists"
  shot "$ST" "$OUT/04-quotes-nested-$a.png"      --appearance $a --scroll-to-text "## Block quotes"
  shot "$ST" "$OUT/05-code-long-$a.png"          --appearance $a --scroll-to-text "## Code"
  shot "$ST" "$OUT/06-tables-rules-$a.png"       --appearance $a --scroll-to-text "## Tables"
  shot "$ST" "$OUT/07-html-cjk-rtl-$a.png"       --appearance $a --scroll-to-text "## HTML and comments"
  # the selection as a key window shows it (translucent: the bands stay visible), over a quote and the code block inside it
  shot "$ST" "$OUT/08-selection-$a.png"          --appearance $a --scroll-to-text "## Block quotes" --select-text "a quote may span:let quoted" --active-selection --height 700
  shot "$ST" "$OUT/09-conflict-banner-$a.png"    --appearance $a --conflict --height 420
  shot "$ST" "$OUT/13-increase-contrast-$a.png"  --appearance $a --increase-contrast --scroll-to-text "## Block quotes"
done
"$ST" --selftest corpus --bytes 1000000 --out "$WORK/corpus.md" --workdir="$WORK/c" > /dev/null
for a in light dark; do
  "$ST" --selftest render --input "$WORK/corpus.md" --out "$OUT/10-corpus-1mb-middle-$a.png" --appearance $a --scroll-to-char 500000 --workdir="$WORK/w" | grep -E "FAIL|rendered" | sed 's/(.*KB/(KB/'
done
shot "$ST" "$OUT/11-narrow-420-light.png"        --appearance light --width 420 --height 900 --scroll-to-text "## Block quotes"
shot "$ST" "$OUT/12-font-size-20-dark.png"       --appearance dark --font-size 20 --height 700

# hanging indent of list items (docs/showcase.md, "## Long list items"): a wide and a narrow window; 16-hanging-before-420-light.png is made with BEFORE below
for a in light dark; do
  shot "$ST" "$OUT/16-hanging-860-$a.png"         --appearance $a --width 860 --height 1000 --scroll-to-text "## Long list items"
  shot "$ST" "$OUT/16-hanging-420-$a.png"         --appearance $a --width 420 --height 1500 --scroll-to-text "## Long list items"
done
# the same page with other settings (Settings: text font, code font, size, line spacing, column width, colour scheme)
shot "$ST" "$OUT/18-settings-combined.png"        --appearance light --width 700 --height 1100 --scroll-to-text "## Long list items" --body-font Georgia --code-font Menlo --font-size 18 --line-spacing 1.7 --column-width 600
shot "$ST" "$OUT/18-settings-combined-dracula.png" --scheme dracula --width 700 --height 1100 --scroll-to-text "## Lists" --body-font "Avenir Next" --font-size 15 --line-spacing 1.35

# the Settings window itself (settings-render): the default look in light and dark, a forced dark scheme on a light system, other fonts / spacing / column
sshot() {   # sshot <out> <args...>      (SBIN: the build to render with; ST by default)
  local out="$1"; shift; n=$((n+1))
  "${SBIN:-$ST}" --selftest settings-render --out "$out" --workdir="$WORK/s$n" "$@" | grep -E "FAIL|rendered" | sed 's/(.*KB/(KB/'
}
n=100
sshot "$OUT/17-settings-light.png"               --appearance light --width 700
sshot "$OUT/17-settings-dark.png"                --appearance dark --width 700
sshot "$OUT/17-settings-scheme-dracula.png"      --appearance light --scheme dracula --width 700
sshot "$OUT/17-settings-fonts.png"               --appearance light --body-font Georgia --code-font Menlo --font-size 19 --line-spacing 1.6 --column-width 600 --width 700

if [ -n "${CLASSIC:-}" ]; then
  mkdir -p "$OUT/classic-look"
  for a in light dark; do shot "$CLASSIC" "$OUT/classic-look/09-conflict-banner-$a.png" --appearance $a --conflict --height 420; done
  shot "$CLASSIC" "$OUT/classic-look/02-emphasis-links-light.png" --appearance light --scroll-to-text "## Emphasis and friends"
  SBIN="$CLASSIC"
  sshot "$OUT/classic-look/17-settings-light.png"               --appearance light --width 700
  sshot "$OUT/classic-look/17-settings-dark.png"                --appearance dark --width 700
  sshot "$OUT/classic-look/17-settings-scheme-dracula.png"      --appearance light --scheme dracula --width 700
  sshot "$OUT/classic-look/17-settings-fonts.png"               --appearance light --body-font Georgia --code-font Menlo --font-size 19 --line-spacing 1.6 --column-width 600 --width 700
  SBIN=""
fi

if [ -n "${BEFORE:-}" ]; then
  mkdir -p "$OUT/before"
  for a in light dark; do
    shot "$BEFORE" "$OUT/before/01-top-$a.png"             --appearance $a
    shot "$BEFORE" "$OUT/before/04-quotes-nested-$a.png"   --appearance $a --scroll-to-text "## Block quotes"
    shot "$BEFORE" "$OUT/before/05-code-long-$a.png"       --appearance $a --scroll-to-text "## Code"
    shot "$BEFORE" "$OUT/before/06-tables-rules-$a.png"    --appearance $a --scroll-to-text "## Tables"
    shot "$BEFORE" "$OUT/before/07-html-cjk-rtl-$a.png"    --appearance $a --scroll-to-text "## HTML and comments"
    shot "$BEFORE" "$OUT/before/08-selection-$a.png"       --appearance $a --scroll-to-text "## Block quotes" --select-text "a quote may span:let quoted" --active-selection --height 700
  done
  shot "$BEFORE" "$OUT/before/11-narrow-420-light.png"     --appearance light --width 420 --height 900 --scroll-to-text "## Block quotes"
  shot "$BEFORE" "$OUT/16-hanging-before-420-light.png"    --appearance light --width 420 --height 1500 --scroll-to-text "## Long list items"
fi
