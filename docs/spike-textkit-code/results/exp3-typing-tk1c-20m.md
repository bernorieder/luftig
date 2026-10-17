### typing latency (ms per keystroke; N=60 after 10 warm-up keystrokes; total = insertText(incl. restyle) + layoutVisible + cacheDisplay(visible)) 
| corpus | engine | position | restyle | navigation to position (jump / style / settle ms) | total med | p95 | max | insertText med | of which restyle med | layout med | draw (cacheDisplay) med | dirty-rect draw (displayIfNeeded) med |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 20m | TK1-contig | start | yes | 0.0 / 4.6 / 10.3 | **3.43** | 3.63 | 3.84 | 0.76 | 0.00 | 0.01 | 2.67 | 0.42 |
| 20m | TK1-contig | middle | yes | 3405.0 / 4.7 / 6.9 | **3.79** | 3.91 | 3.97 | 0.81 | 0.01 | 0.01 | 2.94 | 0.43 |
| 20m | TK1-contig | end | yes | 6770.3 / 2.9 / 5.2 | **2.75** | 2.94 | 3.11 | 0.18 | 0.00 | 0.00 | 2.58 | 0.33 |
