
### 6c. TK1 backgroundLayoutEnabled
| corpus | engine | backgroundLayoutEnabled | open total med ms | max stall in 1 s idle ms | docH after open -> after idle |
|---|---|---|---|---|---|
| 5m | TK1-contig | true | 10.8 | 2336.5 | 788.0 -> 2587.0 |
| 5m | TK1-contig | false | 10.7 | 8.2 | 788.0 -> 824.0 |
| 5m | TK1-noncontig | true | 18.9 | 8.9 | 1091285.0 -> 1091285.0 |
| 5m | TK1-noncontig | false | 21.6 | 10.2 | 1091285.0 -> 1091285.0 |
| 20m | TK1-noncontig | true | 33.2 | 7.0 | 4362903.0 -> 4362903.0 |
| 20m | TK1-noncontig | false | 32.7 | 7.0 | 4362903.0 -> 4362903.0 |
