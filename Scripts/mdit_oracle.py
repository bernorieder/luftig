#!/usr/bin/env python3
"""Second, independent CommonMark oracle for the MarkdownKit lexer: markdown-it-py (spec-compliant, 100 % of the
CommonMark 0.31 examples) with its table and strikethrough rules switched on.

Used only by the differential tests of `mdkit-checks` (never by the app):

    mdkit-checks --mdit-export docs.jsonl <corpus|gen|block|inline> [count] [seed]     # writes {"id":..,"text":..} lines
    /opt/homebrew/anaconda3/bin/python -I Scripts/mdit_oracle.py docs.jsonl oracle.jsonl # this script
    mdkit-checks --mdit-compare docs.jsonl oracle.jsonl [show=N] [link]                 # compares both token streams

For every document the output has one line {"id":..,"runs":[[flags,"text"],..]}: the visible text (what a renderer would
show: no markers, no link destinations, no HTML) in document order, each piece with the flags that apply to it, using the bit
layout of `OFlag` in Oracle.swift: em 1, strong 2, code 4, strike 8, link 16, image 32, code block 64, block quote 128,
table 256, heading level << 9.  Nothing is written anywhere except the output file named on the command line.
"""
import json
import sys

from markdown_it import MarkdownIt

EM, STRONG, CODE, STRIKE, LINK, IMG, CODEBLOCK, QUOTE, TABLE = 1, 2, 4, 8, 16, 32, 64, 128, 256


def make_parser():
    md = MarkdownIt("commonmark", {"html": True, "maxNesting": 100})
    md.enable(["table", "strikethrough"])
    return md


def walk_inline(children, base, out):
    em = strong = strike = link = img = 0
    for t in children:
        ty = t.type
        if ty in ("text", "text_special", "entity"):
            f = base | (EM if em else 0) | (STRONG if strong else 0) | (STRIKE if strike else 0) | (LINK if link else 0) | (IMG if img else 0)
            out.append([f, t.content])
        elif ty == "code_inline":
            f = base | CODE | (EM if em else 0) | (STRONG if strong else 0) | (STRIKE if strike else 0) | (LINK if link else 0) | (IMG if img else 0)
            out.append([f, t.content])
        elif ty in ("softbreak", "hardbreak"):
            out.append([0, "\n"])
        elif ty == "em_open":
            em += 1
        elif ty == "em_close":
            em -= 1
        elif ty == "strong_open":
            strong += 1
        elif ty == "strong_close":
            strong -= 1
        elif ty == "s_open":
            strike += 1
        elif ty == "s_close":
            strike -= 1
        elif ty == "link_open":
            link += 1
        elif ty == "link_close":
            link -= 1
        elif ty == "image":
            img_base = base | (EM if em else 0) | (STRONG if strong else 0) | (STRIKE if strike else 0) | (LINK if link else 0) | IMG
            if t.children:
                walk_inline(t.children, img_base, out)
            else:
                out.append([img_base, t.content])
        # html_inline: not text


def convert(md, text):
    tokens = md.parse(text)
    out = []
    quote = table = heading = 0
    for t in tokens:
        ty = t.type
        if ty == "blockquote_open":
            quote += 1
        elif ty == "blockquote_close":
            quote -= 1
        elif ty == "table_open":
            table += 1
        elif ty == "table_close":
            table -= 1
        elif ty == "heading_open":
            heading = int(t.tag[1])
        elif ty == "heading_close":
            heading = 0
        elif ty in ("fence", "code_block"):
            f = CODEBLOCK | (QUOTE if quote else 0) | (TABLE if table else 0) | (heading << 9)
            out.append([f, t.content])
        elif ty == "inline":
            base = (QUOTE if quote else 0) | (TABLE if table else 0) | (heading << 9)
            walk_inline(t.children or [], base, out)
            out.append([0, "\n"])
        # html_block, hr: no visible text
    # merge neighbours with equal flags
    merged = []
    for f, s in out:
        if merged and merged[-1][0] == f:
            merged[-1][1] += s
        else:
            merged.append([f, s])
    return merged


def main():
    src, dst = sys.argv[1], sys.argv[2]
    md = make_parser()
    n = 0
    with open(src, "r", encoding="utf-8") as fin, open(dst, "w", encoding="utf-8") as fout:
        for line in fin:
            line = line.strip()
            if not line:
                continue
            d = json.loads(line)
            try:
                runs = convert(md, d["text"])
                rec = {"id": d["id"], "runs": runs}
            except Exception as e:  # recursion limits and the like: reported, not fatal
                rec = {"id": d["id"], "error": repr(e)[:200]}
            fout.write(json.dumps(rec, ensure_ascii=False) + "\n")
            n += 1
    print("converted %d documents" % n)


if __name__ == "__main__":
    main()
