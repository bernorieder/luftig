### visual marking: snapshots in /Users/rieder/Developer/Scribe/docs/spike-textkit-code/snapshots
| engine | appearance | case | band left edge pt | band right edge pt | margin-column rows / rows differing (gaps) |
|---|---|---|---|---|---|
| TK1-noncontig | light | basic | 20.0 | 700.0 | 262 / 0 |
| TK1-noncontig | light | scrolled (block cut by top edge) | 20.0 | 700.0 | 94 / 0 |
| TK1-noncontig | light | edited vs fresh render: differing pixels / max delta | 0 | 0 | |
| TK1-noncontig | dark | basic | 20.0 | 700.0 | 262 / 0 |
| TK1-noncontig | dark | scrolled (block cut by top edge) | 20.0 | 700.0 | 94 / 0 |
| TK1-noncontig | dark | edited vs fresh render: differing pixels / max delta | 0 | 0 | |
| TK2 | light | basic | 20.0 | 700.0 | 262 / 0 |
| TK2 | light | scrolled (block cut by top edge) | 20.0 | 700.0 | 94 / 0 |
| TK2 | light | edited vs fresh render: differing pixels / max delta | 0 | 0 | |
| TK2 | dark | basic | 20.0 | 700.0 | 262 / 0 |
| TK2 | dark | scrolled (block cut by top edge) | 20.0 | 700.0 | 94 / 0 |
| TK2 | dark | edited vs fresh render: differing pixels / max delta | 0 | 0 | |

### partial-redraw seam test (full draw vs two independent strips, boundary cutting through the code block)
| engine | appearance | split y (pt from top) | differing pixels | max channel delta |
|---|---|---|---|---|
| TK1-noncontig | light | 396.0 | 0 | 0 |
| TK1-noncontig | light | 417.5 | 0 | 0 |
| TK1-noncontig | light | 452.0 | 0 | 0 |
| TK1-noncontig | dark | 396.0 | 0 | 0 |
| TK1-noncontig | dark | 417.5 | 0 | 0 |
| TK1-noncontig | dark | 452.0 | 0 | 0 |
| TK2 | light | 396.0 | 0 | 0 |
| TK2 | light | 417.5 | 0 | 0 |
| TK2 | light | 452.0 | 0 | 0 |
| TK2 | dark | 396.0 | 0 | 0 |
| TK2 | dark | 417.5 | 0 | 0 |
| TK2 | dark | 452.0 | 0 | 0 |

### decoration draw cost (first screen of the 1 MB corpus, cacheDisplay of the visible area, median of 15)
| engine | decorations | draw ms |
|---|---|---|
| TK1-noncontig | off | 0.66 |
| TK1-noncontig | on | 2.67 |
| TK2 | off | 1.01 |
| TK2 | on | 2.97 |
