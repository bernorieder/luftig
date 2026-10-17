### 6a. typing latency per NSTextView switch (1 MB doc, caret in first screen, 60 keystrokes; total = insertText + layout + full visible redraw; first responder set; run loop spun 4 ms between keys)
| engine | variant | total med ms | p95 | insertText med ms | max run-loop stall while spinning ms |
|---|---|---|---|---|---|
| TK1-noncontig | recommended (plain text, all substitutions off) | 5.14 | 5.27 | 2.13 | 4.9 |
| TK1-noncontig | isRichText = true | 5.55 | 5.63 | 2.35 | 5.6 |
| TK1-noncontig | allowsUndo = false | 5.59 | 5.69 | 2.40 | 2.3 |
| TK1-noncontig | continuous spell checking on | 5.31 | 5.64 | 2.25 | 3.1 |
| TK1-noncontig | spell + grammar + autocorrect on | 5.40 | 5.61 | 2.26 | 3.1 |
| TK1-noncontig | automatic link detection on | 5.95 | 6.33 | 2.79 | 2.3 |
| TK1-noncontig | automatic data detection on | 5.53 | 5.73 | 2.28 | 2.5 |
| TK1-noncontig | smart quotes + dashes + text replacement on | 5.45 | 5.61 | 2.25 | 2.9 |
| TK1-noncontig | usesFindBar + incremental searching | 5.54 | 5.72 | 2.36 | 3.1 |
| TK1-noncontig | usesRuler / inspector bar / font panel on | 5.57 | 5.69 | 2.44 | 2.8 |
| TK1-noncontig | everything a stock NSTextView has on | 5.76 | 6.08 | 2.70 | 2.7 |
| TK2 | recommended (plain text, all substitutions off) | 5.60 | 5.76 | 1.28 | 3.1 |
| TK2 | isRichText = true | 5.59 | 5.76 | 1.23 | 3.5 |
| TK2 | allowsUndo = false | 5.57 | 5.83 | 1.25 | 3.1 |
| TK2 | continuous spell checking on | 5.11 | 5.40 | 1.20 | 3.1 |
| TK2 | spell + grammar + autocorrect on | 4.95 | 5.23 | 1.16 | 3.1 |
| TK2 | automatic link detection on | 6.85 | 6.97 | 2.74 | 4.2 |
| TK2 | automatic data detection on | 5.59 | 6.02 | 1.24 | 3.0 |
| TK2 | smart quotes + dashes + text replacement on | 5.54 | 5.87 | 1.24 | 3.1 |
| TK2 | usesFindBar + incremental searching | 5.56 | 5.94 | 1.26 | 3.1 |
| TK2 | usesRuler / inspector bar / font panel on | 5.51 | 5.86 | 1.37 | 3.0 |
| TK2 | everything a stock NSTextView has on | 6.43 | 6.88 | 2.66 | 1.7 |

### 6b. open time per switch (total to first styled screen, median of 5, ms; idle = 0.5 s run-loop spin, max stall)
| corpus | engine | variant | open total med | max stall in idle ms |
|---|---|---|---|---|
| 1m | TK1-noncontig | recommended (plain text, all substitutions off) | 18.3 | 20.8 |
| 1m | TK1-noncontig | isRichText = true | 9.7 | 9.4 |
| 1m | TK1-noncontig | allowsUndo = false | 9.5 | 5.9 |
| 1m | TK1-noncontig | continuous spell checking on | 9.7 | 6.2 |
| 1m | TK1-noncontig | spell + grammar + autocorrect on | 9.7 | 5.9 |
| 1m | TK1-noncontig | automatic link detection on | 9.1 | 5.7 |
| 1m | TK1-noncontig | automatic data detection on | 9.6 | 5.8 |
| 1m | TK1-noncontig | smart quotes + dashes + text replacement on | 9.5 | 5.9 |
| 1m | TK1-noncontig | usesFindBar + incremental searching | 9.5 | 5.8 |
| 1m | TK1-noncontig | usesRuler / inspector bar / font panel on | 10.3 | 10.1 |
| 1m | TK1-noncontig | everything a stock NSTextView has on | 9.5 | 5.7 |
| 1m | TK2 | recommended (plain text, all substitutions off) | 9.3 | 5.1 |
| 1m | TK2 | isRichText = true | 9.5 | 5.3 |
| 1m | TK2 | allowsUndo = false | 9.4 | 5.3 |
| 1m | TK2 | continuous spell checking on | 9.6 | 7.3 |
| 1m | TK2 | spell + grammar + autocorrect on | 9.3 | 6.4 |
| 1m | TK2 | automatic link detection on | 9.2 | 4.9 |
| 1m | TK2 | automatic data detection on | 16.8 | 7.9 |
| 1m | TK2 | smart quotes + dashes + text replacement on | 17.4 | 8.2 |
| 1m | TK2 | usesFindBar + incremental searching | 11.7 | 8.1 |
| 1m | TK2 | usesRuler / inspector bar / font panel on | 9.2 | 10.0 |
| 1m | TK2 | everything a stock NSTextView has on | 9.5 | 5.8 |
| 20m | TK1-noncontig | recommended (plain text, all substitutions off) | 21.2 | 6.6 |
| 20m | TK1-noncontig | isRichText = true | 19.9 | 6.4 |
| 20m | TK1-noncontig | allowsUndo = false | 19.8 | 6.1 |
| 20m | TK1-noncontig | continuous spell checking on | 19.7 | 5.7 |
| 20m | TK1-noncontig | spell + grammar + autocorrect on | 19.7 | 5.6 |
| 20m | TK1-noncontig | automatic link detection on | 19.7 | 19.7 |
| 20m | TK1-noncontig | automatic data detection on | 20.0 | 7.8 |
| 20m | TK1-noncontig | smart quotes + dashes + text replacement on | 19.6 | 5.6 |
| 20m | TK1-noncontig | usesFindBar + incremental searching | 19.7 | 5.6 |
| 20m | TK1-noncontig | usesRuler / inspector bar / font panel on | 20.6 | 10.2 |
| 20m | TK1-noncontig | everything a stock NSTextView has on | 19.9 | 8.6 |
| 20m | TK2 | recommended (plain text, all substitutions off) | 31.8 | 6.2 |
| 20m | TK2 | isRichText = true | 32.3 | 6.5 |
| 20m | TK2 | allowsUndo = false | 29.4 | 6.4 |
| 20m | TK2 | continuous spell checking on | 30.0 | 8.9 |
| 20m | TK2 | spell + grammar + autocorrect on | 28.9 | 6.3 |
| 20m | TK2 | automatic link detection on | 32.0 | 6.6 |
| 20m | TK2 | automatic data detection on | 32.9 | 6.4 |
| 20m | TK2 | smart quotes + dashes + text replacement on | 33.7 | 7.8 |
| 20m | TK2 | usesFindBar + incremental searching | 24.0 | 6.4 |
| 20m | TK2 | usesRuler / inspector bar / font panel on | 19.6 | 10.6 |
| 20m | TK2 | everything a stock NSTextView has on | 19.8 | 5.2 |

### 6c. TK1 backgroundLayoutEnabled
| corpus | engine | backgroundLayoutEnabled | open total med ms | max stall in 1 s idle ms | docH after open -> after idle |
|---|---|---|---|---|---|
| 5m | TK1-contig | true | 10.0 | 0.0 | 788.0 -> 2587.0 |
| 5m | TK1-contig | false | 10.1 | 9.4 | 788.0 -> 824.0 |
| 5m | TK1-noncontig | true | 11.7 | 5.7 | 1091285.0 -> 1091285.0 |
| 5m | TK1-noncontig | false | 11.9 | 5.9 | 1091285.0 -> 1091285.0 |
| 20m | TK1-noncontig | true | 20.5 | 6.1 | 4362903.0 -> 4362903.0 |
| 20m | TK1-noncontig | false | 33.9 | 8.2 | 4362903.0 -> 4362903.0 |

### 6d. find: cost of the string search NSTextFinder performs (NSString.range(of:), whole document, miss = worst case); the find pasteboard is NOT touched
| corpus | needle | options | time ms |
|---|---|---|---|
| 1m | miss | literal | 4.7 |
| 1m | miss | caseInsensitive | 4.7 |
| 1m | miss | case+diacritic insensitive | 4.7 |
| 1m | rare hit (non-BMP) | literal | 0.1 |
| 1m | rare hit (non-BMP) | caseInsensitive | 0.1 |
| 1m | rare hit (non-BMP) | case+diacritic insensitive | 0.1 |
| 5m | miss | literal | 18.1 |
| 5m | miss | caseInsensitive | 18.1 |
| 5m | miss | case+diacritic insensitive | 17.0 |
| 5m | rare hit (non-BMP) | literal | 0.0 |
| 5m | rare hit (non-BMP) | caseInsensitive | 0.0 |
| 5m | rare hit (non-BMP) | case+diacritic insensitive | 0.0 |
| 20m | miss | literal | 58.3 |
| 20m | miss | caseInsensitive | 61.3 |
| 20m | miss | case+diacritic insensitive | 60.5 |
| 20m | rare hit (non-BMP) | literal | 0.0 |
| 20m | rare hit (non-BMP) | caseInsensitive | 0.0 |
| 20m | rare hit (non-BMP) | case+diacritic insensitive | 0.0 |

### 6e. window resize with a readable max column (inset computed from the clip width): per 1-pt step 900 -> 860 -> 900, ms per step (setContentSize + inset + layout visible + redraw)
| corpus | engine | position | inset update | step med | p95 | max |
|---|---|---|---|---|---|---|
| 1m | TK1-noncontig | top | no | 4.81 | 5.19 | 5.74 |
| 1m | TK1-noncontig | top | yes | 5.38 | 5.82 | 6.71 |
| 1m | TK1-noncontig | middle | no | 8.05 | 8.46 | 10.45 |
| 1m | TK1-noncontig | middle | yes | 9.92 | 15.78 | 29.02 |
| 1m | TK2 | top | no | 5.12 | 5.42 | 5.90 |
| 1m | TK2 | top | yes | 4.85 | 5.04 | 6.25 |
| 1m | TK2 | middle | no | 2.92 | 3.08 | 6.30 |
| 1m | TK2 | middle | yes | 2.96 | 3.05 | 5.68 |
| 20m | TK1-noncontig | top | no | 5.78 | 10.43 | 20.71 |
| 20m | TK1-noncontig | top | yes | 5.85 | 10.29 | 20.32 |
| 20m | TK1-noncontig | middle | no | 8.30 | 8.64 | 10.62 |
| 20m | TK1-noncontig | middle | yes | 10.47 | 16.21 | 22.66 |
| 20m | TK2 | top | no | 6.00 | 10.54 | 20.38 |
| 20m | TK2 | top | yes | 4.95 | 5.20 | 6.60 |
| 20m | TK2 | middle | no | 2.89 | 3.01 | 5.12 |
| 20m | TK2 | middle | yes | 2.92 | 3.02 | 5.61 |

### 6f. where is the viewport after a resize? (20 MB doc, scrolled to the middle; width 900 -> 600; top visible char as fraction of the document)
| engine | before | after resize (nothing done) | after resize + anchor restore | restore ms |
|---|---|---|---|---|
| TK1-noncontig | 0.49997 | 0.49997 | 0.49997 | 0.0 |
| TK2 | 0.49998 | 0.40877 | 0.40883 | 1.7 |
