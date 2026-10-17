### open: runs=3 styled=true idle=0.5s  (ms; breakdown = medians of runs 2..N; cold = run 1 total)
| corpus | engine | set mode | cold total | **total med** [min..max] | set | base attrs | style 1st screen | layout | draw | RSS Δ MB | docH after open -> after 0.5s | max stall in idle ms |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 2m-oneline | TK1-noncontig | textView.string= | 1093.6 | **1038.5** [1031.9..1045.0] | 529.0 | 0.0 | 505.9 | 0.0 | 3.5 | 20.0 | 302325.0 -> 302325.0 | 6.3 |
| 2m-oneline | TK2 | textView.string= | 692.6 | **688.0** [685.8..690.2] | 1.2 | 0.0 | 0.0 | 359.5 | 327.4 | 93.0 | 301132.0 -> 301132.0 | 25.3 |
