
#### corpus 1m: 997320 UTF-16 units; Doc prep: UTF-16 copy 2.6 ms, fence scan 0.4 ms (1012 fences)
150 lines at top = 6401 UTF-16 units, 560 coalesced runs
viewport-slice used: 280 lines, 12082 units, 1026 runs
| engine | placement | variant | runs | loop ms | endEditing ms | layout ms | draw ms | total ms |
|---|---|---|---|---|---|---|---|---|
| TK1-contig | visible | setAttributes batched | 1026 | 0.62 | 0.01 | 1.94 | 3.83 | **6.31** |
| TK1-contig | visible | addAttributes batched | 1026 | 1.73 | 0.00 | 1.84 | 2.94 | **6.52** |
| TK1-contig | visible | setAttributes batched, per-token runs | 4163 | 2.33 | 0.00 | 1.81 | 2.89 | **7.06** |
| TK1-contig | visible | setAttributes UNbatched | 1026 | 2.31 | 0.00 | 1.82 | 2.90 | **7.03** |
| TK1-contig | below viewport | setAttributes batched | 1011 | 0.59 | 0.00 | 0.00 | 2.40 | **2.97** |
| TK1-contig | below viewport | addAttributes batched | 1011 | 1.69 | 0.01 | 0.00 | 2.39 | **4.09** |
| TK1-contig | below viewport | setAttributes batched, per-token runs | 3176 | 1.82 | 0.00 | 0.00 | 2.39 | **4.19** |
| TK1-contig | below viewport | setAttributes UNbatched | 1011 | 2.32 | 0.00 | 0.00 | 2.44 | **4.76** |
| TK1-contig | middle of doc | setAttributes batched | 1020 | 0.59 | 0.00 | 0.00 | 2.35 | **2.94** |
| TK1-contig | middle of doc | addAttributes batched | 1020 | 1.74 | 0.00 | 0.00 | 2.36 | **4.13** |
| TK1-contig | middle of doc | setAttributes batched, per-token runs | 3625 | 2.01 | 0.00 | 0.00 | 2.35 | **4.37** |
| TK1-contig | middle of doc | setAttributes UNbatched | 1020 | 2.28 | 0.00 | 0.00 | 2.40 | **4.68** |
| TK1-noncontig | visible | setAttributes batched | 1026 | 0.59 | 2.30 | 0.00 | 2.99 | **5.86** |
| TK1-noncontig | visible | addAttributes batched | 1026 | 1.75 | 2.26 | 0.00 | 2.95 | **6.96** |
| TK1-noncontig | visible | setAttributes batched, per-token runs | 4163 | 2.33 | 2.23 | 0.00 | 2.92 | **7.49** |
| TK1-noncontig | visible | setAttributes UNbatched | 1026 | 82.68 | 0.00 | 1.18 | 2.98 | **86.84** |
| TK1-noncontig | below viewport | setAttributes batched | 1011 | 0.57 | 0.01 | 0.00 | 2.38 | **2.97** |
| TK1-noncontig | below viewport | addAttributes batched | 1011 | 1.65 | 0.01 | 0.00 | 2.39 | **4.08** |
| TK1-noncontig | below viewport | setAttributes batched, per-token runs | 3176 | 1.77 | 0.01 | 0.00 | 2.35 | **4.12** |
| TK1-noncontig | below viewport | setAttributes UNbatched | 1011 | 5.07 | 0.00 | 0.00 | 2.37 | **7.44** |
| TK1-noncontig | middle of doc | setAttributes batched | 1020 | 0.58 | 0.01 | 0.00 | 2.36 | **2.94** |
| TK1-noncontig | middle of doc | addAttributes batched | 1020 | 1.71 | 0.01 | 0.00 | 2.39 | **4.09** |
| TK1-noncontig | middle of doc | setAttributes batched, per-token runs | 3625 | 2.03 | 0.01 | 0.00 | 2.38 | **4.42** |
| TK1-noncontig | middle of doc | setAttributes UNbatched | 1020 | 5.47 | 0.00 | 0.00 | 2.38 | **7.86** |
| TK2 | visible | setAttributes batched | 1026 | 0.58 | 0.12 | 2.42 | 4.17 | **7.30** |
| TK2 | visible | addAttributes batched | 1026 | 1.70 | 0.11 | 2.29 | 4.06 | **8.18** |
| TK2 | visible | setAttributes batched, per-token runs | 4163 | 2.27 | 0.11 | 2.29 | 4.08 | **8.79** |
| TK2 | visible | setAttributes UNbatched | 1026 | 18.90 | 0.00 | 2.30 | 4.13 | **25.32** |
| TK2 | below viewport | setAttributes batched | 1011 | 0.56 | 0.05 | 0.46 | 2.92 | **3.98** |
| TK2 | below viewport | addAttributes batched | 1011 | 1.63 | 0.05 | 0.47 | 2.82 | **4.97** |
| TK2 | below viewport | setAttributes batched, per-token runs | 3176 | 1.78 | 0.05 | 0.45 | 2.84 | **5.14** |
| TK2 | below viewport | setAttributes UNbatched | 1011 | 18.62 | 0.00 | 0.47 | 2.87 | **21.96** |
| TK2 | middle of doc | setAttributes batched | 1020 | 0.59 | 0.05 | 0.46 | 2.85 | **3.93** |
| TK2 | middle of doc | addAttributes batched | 1020 | 1.68 | 0.05 | 0.47 | 2.80 | **5.01** |
| TK2 | middle of doc | setAttributes batched, per-token runs | 3625 | 1.97 | 0.05 | 0.45 | 2.82 | **5.27** |
| TK2 | middle of doc | setAttributes UNbatched | 1020 | 18.84 | 0.00 | 0.44 | 2.82 | **22.09** |

Whole-document styling (lex everything, setAttributes for every run, one beginEditing/endEditing):
| engine | corpus | runs | lex ms | apply loop ms | endEditing ms | layout visible ms | draw ms | idle 1s max stall ms | RSS Δ MB |
|---|---|---|---|---|---|---|---|---|---|
| TK1-contig | 1m | 85910 | 2.5 | 49.1 | 0.0 | 3.3 | 4.1 | 337.3 | 19.9 |
| TK1-noncontig | 1m | 85910 | 2.5 | 54.8 | 4.2 | 0.0 | 4.1 | 294.8 | 9.8 |
| TK2 | 1m | 85910 | 2.5 | 62.3 | 2.5 | 3.6 | 6.2 | 6.5 | 9.8 |

#### corpus 5m: 4986175 UTF-16 units; Doc prep: UTF-16 copy 14.6 ms, fence scan 2.0 ms (5058 fences)
150 lines at top = 6401 UTF-16 units, 560 coalesced runs
viewport-slice used: 280 lines, 12082 units, 1026 runs
| engine | placement | variant | runs | loop ms | endEditing ms | layout ms | draw ms | total ms |
|---|---|---|---|---|---|---|---|---|
| TK1-contig | visible | setAttributes batched | 1026 | 0.61 | 0.01 | 1.88 | 3.76 | **6.19** |
| TK1-contig | visible | addAttributes batched | 1026 | 1.68 | 0.01 | 1.84 | 2.93 | **6.45** |
| TK1-contig | visible | setAttributes batched, per-token runs | 4163 | 2.33 | 0.00 | 1.82 | 2.93 | **7.10** |
| TK1-contig | visible | setAttributes UNbatched | 1026 | 2.28 | 0.00 | 1.82 | 2.89 | **6.98** |
| TK1-contig | below viewport | setAttributes batched | 1011 | 0.59 | 0.01 | 0.00 | 2.37 | **2.99** |
| TK1-contig | below viewport | addAttributes batched | 1011 | 1.62 | 0.00 | 0.00 | 2.32 | **3.97** |
| TK1-contig | below viewport | setAttributes batched, per-token runs | 3176 | 1.86 | 0.00 | 0.00 | 2.34 | **4.21** |
| TK1-contig | below viewport | setAttributes UNbatched | 1011 | 2.25 | 0.00 | 0.00 | 2.33 | **4.58** |
| TK1-contig | middle of doc | setAttributes batched | 1095 | 0.65 | 0.00 | 0.00 | 2.35 | **2.99** |
| TK1-contig | middle of doc | addAttributes batched | 1095 | 1.79 | 0.00 | 0.00 | 2.35 | **4.13** |
| TK1-contig | middle of doc | setAttributes batched, per-token runs | 5086 | 2.95 | 0.01 | 0.00 | 2.34 | **5.30** |
| TK1-contig | middle of doc | setAttributes UNbatched | 1095 | 2.51 | 0.00 | 0.00 | 2.41 | **4.93** |
| TK1-noncontig | visible | setAttributes batched | 1026 | 0.59 | 2.27 | 0.01 | 2.96 | **5.82** |
| TK1-noncontig | visible | addAttributes batched | 1026 | 1.68 | 2.25 | 0.00 | 2.96 | **6.91** |
| TK1-noncontig | visible | setAttributes batched, per-token runs | 4163 | 2.35 | 2.26 | 0.00 | 2.93 | **7.48** |
| TK1-noncontig | visible | setAttributes UNbatched | 1026 | 82.35 | 0.00 | 1.18 | 3.00 | **86.53** |
| TK1-noncontig | below viewport | setAttributes batched | 1011 | 0.61 | 0.01 | 0.00 | 2.41 | **3.01** |
| TK1-noncontig | below viewport | addAttributes batched | 1011 | 1.64 | 0.01 | 0.00 | 2.40 | **4.06** |
| TK1-noncontig | below viewport | setAttributes batched, per-token runs | 3176 | 1.87 | 0.01 | 0.00 | 2.36 | **4.26** |
| TK1-noncontig | below viewport | setAttributes UNbatched | 1011 | 5.06 | 0.00 | 0.00 | 2.38 | **7.45** |
| TK1-noncontig | middle of doc | setAttributes batched | 1095 | 0.65 | 0.01 | 0.00 | 2.36 | **3.03** |
| TK1-noncontig | middle of doc | addAttributes batched | 1095 | 1.77 | 0.01 | 0.00 | 2.35 | **4.13** |
| TK1-noncontig | middle of doc | setAttributes batched, per-token runs | 5086 | 2.88 | 0.01 | 0.00 | 2.34 | **5.23** |
| TK1-noncontig | middle of doc | setAttributes UNbatched | 1095 | 5.83 | 0.00 | 0.00 | 2.37 | **8.20** |
| TK2 | visible | setAttributes batched | 1026 | 0.59 | 0.11 | 2.38 | 4.23 | **7.32** |
| TK2 | visible | addAttributes batched | 1026 | 1.67 | 0.11 | 2.30 | 4.08 | **8.21** |
| TK2 | visible | setAttributes batched, per-token runs | 4163 | 2.31 | 0.11 | 2.27 | 4.06 | **8.84** |
| TK2 | visible | setAttributes UNbatched | 1026 | 18.74 | 0.00 | 2.28 | 4.13 | **25.16** |
| TK2 | below viewport | setAttributes batched | 1011 | 0.58 | 0.05 | 0.46 | 2.85 | **3.93** |
| TK2 | below viewport | addAttributes batched | 1011 | 1.65 | 0.05 | 0.48 | 2.85 | **5.03** |
| TK2 | below viewport | setAttributes batched, per-token runs | 3176 | 1.87 | 0.05 | 0.46 | 2.87 | **5.26** |
| TK2 | below viewport | setAttributes UNbatched | 1011 | 18.69 | 0.00 | 0.47 | 2.88 | **22.04** |
| TK2 | middle of doc | setAttributes batched | 1095 | 0.63 | 0.05 | 0.46 | 2.84 | **3.97** |
| TK2 | middle of doc | addAttributes batched | 1095 | 1.79 | 0.05 | 0.45 | 2.84 | **5.16** |
| TK2 | middle of doc | setAttributes batched, per-token runs | 5086 | 2.81 | 0.05 | 0.46 | 2.82 | **6.15** |
| TK2 | middle of doc | setAttributes UNbatched | 1095 | 20.15 | 0.00 | 0.50 | 2.89 | **23.54** |

Whole-document styling (lex everything, setAttributes for every run, one beginEditing/endEditing):
| engine | corpus | runs | lex ms | apply loop ms | endEditing ms | layout visible ms | draw ms | idle 1s max stall ms | RSS Δ MB |
|---|---|---|---|---|---|---|---|---|---|
| TK1-contig | 5m | 428449 | 12.1 | 238.0 | 0.0 | 7.3 | 4.4 | 33.0 | 109.4 |
| TK1-noncontig | 5m | 428449 | 12.1 | 238.4 | 8.3 | 0.0 | 4.3 | 7.5 | 6.2 |
| TK2 | 5m | 428449 | 12.1 | 242.7 | 11.1 | 3.8 | 5.8 | 6.7 | 14.8 |

#### corpus 20m: 19942150 UTF-16 units; Doc prep: UTF-16 copy 52.2 ms, fence scan 7.0 ms (20102 fences)
150 lines at top = 6401 UTF-16 units, 560 coalesced runs
viewport-slice used: 280 lines, 12082 units, 1026 runs
| engine | placement | variant | runs | loop ms | endEditing ms | layout ms | draw ms | total ms |
|---|---|---|---|---|---|---|---|---|
| TK1-contig | visible | setAttributes batched | 1026 | 0.60 | 0.01 | 1.88 | 3.79 | **6.26** |
| TK1-contig | visible | addAttributes batched | 1026 | 1.67 | 0.00 | 1.81 | 3.01 | **6.50** |
| TK1-contig | visible | setAttributes batched, per-token runs | 4163 | 2.34 | 0.00 | 1.79 | 2.91 | **7.03** |
| TK1-contig | visible | setAttributes UNbatched | 1026 | 2.30 | 0.00 | 1.83 | 2.88 | **7.01** |
| TK1-contig | below viewport | setAttributes batched | 1011 | 0.57 | 0.01 | 0.00 | 2.36 | **2.97** |
| TK1-contig | below viewport | addAttributes batched | 1011 | 1.62 | 0.00 | 0.00 | 2.36 | **3.99** |
| TK1-contig | below viewport | setAttributes batched, per-token runs | 3176 | 1.78 | 0.00 | 0.00 | 2.35 | **4.15** |
| TK1-contig | below viewport | setAttributes UNbatched | 1011 | 2.28 | 0.00 | 0.00 | 2.37 | **4.65** |
| TK1-contig | middle of doc | setAttributes batched | 1051 | 0.60 | 0.00 | 0.00 | 2.37 | **2.98** |
| TK1-contig | middle of doc | addAttributes batched | 1051 | 1.69 | 0.00 | 0.00 | 2.36 | **4.06** |
| TK1-contig | middle of doc | setAttributes batched, per-token runs | 5311 | 2.89 | 0.00 | 0.00 | 2.35 | **5.26** |
| TK1-contig | middle of doc | setAttributes UNbatched | 1051 | 2.36 | 0.00 | 0.00 | 2.34 | **4.70** |
| TK1-noncontig | visible | setAttributes batched | 1026 | 0.58 | 2.28 | 0.00 | 2.95 | **5.85** |
| TK1-noncontig | visible | addAttributes batched | 1026 | 1.64 | 2.25 | 0.00 | 2.99 | **6.85** |
| TK1-noncontig | visible | setAttributes batched, per-token runs | 4163 | 2.29 | 2.26 | 0.00 | 3.02 | **7.64** |
| TK1-noncontig | visible | setAttributes UNbatched | 1026 | 84.58 | 0.00 | 1.19 | 3.01 | **88.78** |
| TK1-noncontig | below viewport | setAttributes batched | 1011 | 0.57 | 0.01 | 0.00 | 2.40 | **2.98** |
| TK1-noncontig | below viewport | addAttributes batched | 1011 | 1.59 | 0.01 | 0.00 | 2.38 | **3.98** |
| TK1-noncontig | below viewport | setAttributes batched, per-token runs | 3176 | 1.77 | 0.01 | 0.00 | 2.37 | **4.14** |
| TK1-noncontig | below viewport | setAttributes UNbatched | 1011 | 5.07 | 0.00 | 0.00 | 2.37 | **7.43** |
| TK1-noncontig | middle of doc | setAttributes batched | 1051 | 0.59 | 0.01 | 0.00 | 2.36 | **2.96** |
| TK1-noncontig | middle of doc | addAttributes batched | 1051 | 1.70 | 0.01 | 0.00 | 2.35 | **4.06** |
| TK1-noncontig | middle of doc | setAttributes batched, per-token runs | 5311 | 2.89 | 0.01 | 0.00 | 2.35 | **5.25** |
| TK1-noncontig | middle of doc | setAttributes UNbatched | 1051 | 5.58 | 0.00 | 0.00 | 2.38 | **7.95** |
| TK2 | visible | setAttributes batched | 1026 | 0.58 | 0.11 | 2.35 | 4.19 | **7.25** |
| TK2 | visible | addAttributes batched | 1026 | 1.62 | 0.11 | 2.31 | 4.06 | **8.10** |
| TK2 | visible | setAttributes batched, per-token runs | 4163 | 2.27 | 0.11 | 2.29 | 4.09 | **8.71** |
| TK2 | visible | setAttributes UNbatched | 1026 | 18.91 | 0.00 | 2.28 | 4.08 | **25.27** |
| TK2 | below viewport | setAttributes batched | 1011 | 0.56 | 0.05 | 0.45 | 2.84 | **3.91** |
| TK2 | below viewport | addAttributes batched | 1011 | 1.59 | 0.05 | 0.45 | 2.83 | **4.94** |
| TK2 | below viewport | setAttributes batched, per-token runs | 3176 | 1.76 | 0.05 | 0.44 | 2.82 | **5.08** |
| TK2 | below viewport | setAttributes UNbatched | 1011 | 18.29 | 0.00 | 0.45 | 2.83 | **21.58** |
| TK2 | middle of doc | setAttributes batched | 1051 | 0.59 | 0.05 | 0.46 | 2.82 | **3.93** |
| TK2 | middle of doc | addAttributes batched | 1051 | 1.69 | 0.05 | 0.45 | 2.80 | **4.99** |
| TK2 | middle of doc | setAttributes batched, per-token runs | 5311 | 2.84 | 0.05 | 0.45 | 2.84 | **6.19** |
| TK2 | middle of doc | setAttributes UNbatched | 1051 | 19.58 | 0.00 | 0.49 | 3.00 | **23.07** |

Whole-document styling (lex everything, setAttributes for every run, one beginEditing/endEditing):
| engine | corpus | runs | lex ms | apply loop ms | endEditing ms | layout visible ms | draw ms | idle 1s max stall ms | RSS Δ MB |
|---|---|---|---|---|---|---|---|---|---|
| TK1-contig | 20m | 1714282 | 47.8 | 942.1 | 0.0 | 18.3 | 4.4 | 42.0 | 128.6 |
| TK1-noncontig | 20m | 1714282 | 47.8 | 930.2 | 24.1 | 0.0 | 4.4 | 26.4 | 110.1 |
| TK2 | 20m | 1714282 | 47.8 | 926.9 | 43.9 | 5.0 | 6.3 | 9.0 | 28.8 |
