### open: runs=3 styled=true idle=0.5s  (ms; breakdown = medians of runs 2..N; cold = run 1 total)
| corpus | engine | set mode | cold total | **total med** [min..max] | set | base attrs | style 1st screen | layout | draw | RSS Δ MB | docH after open -> after 0.5s | max stall in idle ms |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1m-long | TK1-noncontig | textView.string= | 36.0 | **12.0** [11.7..12.2] | 2.7 | 0.0 | 3.6 | 0.0 | 5.6 | 10.9 | 218317.0 -> 218317.0 | 6.0 |
| 1m-long | TK2 | textView.string= | 12.8 | **12.3** [11.7..12.8] | 0.6 | 0.0 | 1.0 | 3.5 | 7.2 | 9.9 | 213233.5 -> 213233.5 | 5.2 |
| 20m-long | TK1-noncontig | textView.string= | 42.7 | **23.6** [21.9..25.3] | 14.6 | 0.0 | 3.6 | 0.0 | 5.4 | 29.1 | 4361169.0 -> 4361169.0 | 5.5 |
| 20m-long | TK2 | textView.string= | 28.6 | **35.0** [33.2..36.8] | 19.9 | 0.0 | 1.4 | 4.5 | 9.2 | 9.7 | 4247674.5 -> 4247674.5 | 6.3 |
| 2m-oneline | TK1-noncontig | textView.string= | 1044.6 | **1014.2** [998.0..1030.5] | 528.9 | 0.0 | 482.1 | 0.0 | 3.2 | 17.6 | 302325.0 -> 302325.0 | 5.2 |
| 2m-oneline | TK2 | textView.string= | 665.9 | **663.8** [661.5..666.0] | 2.2 | 0.0 | 0.1 | 356.2 | 305.3 | 93.1 | 301132.0 -> 301132.0 | 22.8 |
| 10m-oneline | TK1-noncontig | textView.string= | 5852.2 | **5795.9** [5731.5..5860.2] | 2971.0 | 0.0 | 2821.6 | 0.0 | 3.2 | 56.9 | 1510566.0 -> 1510566.0 | 5.8 |
| 10m-oneline | TK2 | textView.string= | 3392.0 | **3363.8** [3325.1..3402.4] | 5.5 | 0.0 | 0.0 | 1783.1 | 1575.1 | 418.5 | 1504594.0 -> 1504594.0 | 85.0 |
