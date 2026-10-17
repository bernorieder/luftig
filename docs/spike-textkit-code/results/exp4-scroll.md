
#### scroll steps, corpus 1m (997320 UTF-16 units); step = 350 pt (half a page); lazily style visible +/- 60 lines each step
| engine | mitigation | scenario | step ms med / p95 / max | max |ΔH| per step (pt) | H drift over session (pt) | max visual jump (pt) | steps with jump > 0.5 pt | thumb Δ min / max per step |
|---|---|---|---|---|---|---|---|---|
| TK1-contig | M0 natural heights | down from top | 6.98 / 7.81 / 9.49 | 362.0 | 21613.0 | 278.0 | 91/100 | -0.18387 / 0.56573 |
| TK1-contig | M0 natural heights | up from end | 6.19 / 7.08 / 9.03 | 0.0 | 0.0 | 58.0 | 71/100 | -0.00082 / -0.00082 |
| TK1-contig | M0 + styled-range cache | down from top | 3.41 / 4.53 / 5.24 | 362.0 | 21613.0 | 278.0 | 91/100 | -0.18387 / 0.56573 |
| TK1-contig | M0 + styled-range cache | up from end | 5.04 / 6.06 / 6.59 | 0.0 | 0.0 | 58.0 | 71/100 | -0.00082 / -0.00082 |
| TK1-contig | M1 uniform heights | down from top | 6.50 / 7.10 / 7.53 | 318.5 | 22081.0 | 224.0 | 100/100 | -0.09467 / 0.44570 |
| TK1-contig | M1 uniform heights | up from end | 5.78 / 6.63 / 7.21 | 0.0 | 0.0 | 37.0 | 20/100 | -0.00070 / -0.00070 |
| TK1-contig | M1 + styled-range cache | down from top | 3.18 / 4.30 / 8.44 | 318.5 | 22081.0 | 224.0 | 100/100 | -0.09467 / 0.44570 |
| TK1-contig | M1 + styled-range cache | up from end | 3.51 / 5.11 / 6.04 | 0.0 | 0.0 | 37.0 | 20/100 | -0.00070 / -0.00070 |
| TK1-contig | M0 + anchor compensation | down from top | 6.91 / 7.64 / 8.75 | 362.0 | 21613.0 | 278.0 | 91/100 | -0.18387 / 0.56573 |
| TK1-contig | M0 + anchor compensation | up from end | 6.25 / 7.43 / 7.79 | 0.0 | 0.0 | 0.0 | 0/100 | -0.00092 / -0.00075 |
| TK1-contig | M1 + compensation | down from top | 6.60 / 7.26 / 7.77 | 318.5 | 22081.0 | 224.0 | 100/100 | -0.09467 / 0.44570 |
| TK1-contig | M1 + compensation | up from end | 5.88 / 7.42 / 9.36 | 0.0 | 0.0 | 0.0 | 0/100 | -0.00070 / -0.00060 |
| TK1-contig | M0 NO styling at all | down from top | 1.29 / 1.59 / 1.77 | 329.0 | 21619.0 | 242.0 | 100/100 | -0.18840 / 0.56573 |
| TK1-contig | M0 NO styling at all | up from end | 0.88 / 1.02 / 1.06 | 0.0 | 0.0 | 0.0 | 0/100 | -0.00082 / -0.00082 |
| TK1-noncontig | M0 natural heights | down from top | 7.73 / 8.52 / 10.16 | 332.0 | 16469.0 | 26.0 | 11/100 | 0.00126 / 0.00162 |
| TK1-noncontig | M0 natural heights | up from end | 8.37 / 9.82 / 12.24 | 540.0 | 15164.5 | 48.0 | 15/100 | -0.00177 / -0.00089 |
| TK1-noncontig | M0 + styled-range cache | down from top | 4.11 / 5.74 / 8.43 | 436.0 | 16087.0 | 0.0 | 0/100 | 0.00129 / 0.00161 |
| TK1-noncontig | M0 + styled-range cache | up from end | 5.27 / 6.54 / 9.78 | 540.0 | 16162.0 | 48.0 | 15/100 | -0.00177 / -0.00119 |
| TK1-noncontig | M1 uniform heights | down from top | 7.71 / 8.73 / 10.32 | 546.0 | 18903.0 | 0.0 | 0/100 | 0.00117 / 0.00160 |
| TK1-noncontig | M1 uniform heights | up from end | 7.56 / 9.45 / 10.17 | 678.0 | 18364.5 | 35.0 | 4/100 | -0.00170 / -0.00111 |
| TK1-noncontig | M1 + styled-range cache | down from top | 3.41 / 4.84 / 5.67 | 539.0 | 19078.0 | 0.0 | 0/100 | 0.00120 / 0.00160 |
| TK1-noncontig | M1 + styled-range cache | up from end | 4.73 / 5.94 / 9.56 | 665.0 | 18531.0 | 35.0 | 2/100 | -0.00170 / -0.00107 |
| TK1-noncontig | M0 + anchor compensation | down from top | 7.71 / 8.43 / 8.97 | 408.0 | 16589.0 | 40.0 | 33/100 | 0.00127 / 0.00167 |
| TK1-noncontig | M0 + anchor compensation | up from end | 8.23 / 10.21 / 18.30 | 396.0 | 9632.0 | 396.0 | 91/100 | -0.00177 / 0.00038 |
| TK1-noncontig | M1 + compensation | down from top | 7.55 / 8.49 / 11.93 | 606.0 | 18606.0 | 98.0 | 38/100 | 0.00087 / 0.00160 |
| TK1-noncontig | M1 + compensation | up from end | 7.34 / 9.18 / 10.33 | 650.0 | 11700.0 | 507.5 | 80/100 | -0.00195 / 0.00150 |
| TK1-noncontig | M0 NO styling at all | down from top | 1.30 / 1.67 / 2.10 | 456.0 | 16497.0 | 0.0 | 0/100 | 0.00126 / 0.00161 |
| TK1-noncontig | M0 NO styling at all | up from end | 1.66 / 2.03 / 2.14 | 458.0 | 16317.5 | 0.3 | 0/100 | -0.00159 / -0.00123 |
| TK2 | M0 natural heights | down from top | 8.72 / 9.91 / 11.26 | 284946.5 | 28766.5 | 166.8 | 98/100 | -0.02450 / 0.03178 |
| TK2 | M0 natural heights | up from end | 9.05 / 10.38 / 10.97 | 13315.5 | 12748.5 | 185.6 | 78/100 | -0.02934 / 0.03238 |
| TK2 | M0 + styled-range cache | down from top | 5.91 / 7.51 / 11.04 | 359434.5 | 45759.5 | 350.0 | 1/100 | -0.02544 / 0.04307 |
| TK2 | M0 + styled-range cache | up from end | 6.73 / 8.55 / 9.47 | 4597.0 | 8489.0 | 0.0 | 0/100 | -0.01195 / -0.00037 |
| TK2 | M1 uniform heights | down from top | 7.92 / 8.95 / 10.86 | 384832.0 | 181754.0 | 166.7 | 99/100 | -0.02684 / 0.02521 |
| TK2 | M1 uniform heights | up from end | 8.48 / 10.16 / 13.35 | 11599.0 | 12743.0 | 291.6 | 71/100 | -0.02486 / 0.01594 |
| TK2 | M1 + styled-range cache | down from top | 5.37 / 6.41 / 7.25 | 462374.5 | 342460.0 | 0.0 | 0/100 | -0.02576 / 0.04182 |
| TK2 | M1 + styled-range cache | up from end | 5.85 / 7.54 / 9.67 | 188.0 | 4120.0 | 0.0 | 0/100 | -0.00124 / -0.00034 |
| TK2 | M0 + anchor compensation | down from top | 9.92 / 11.02 / 11.71 | 357260.5 | 19214.5 | 537.9 | 4/100 | -0.02356 / 0.02702 |
| TK2 | M0 + anchor compensation | up from end | 10.12 / 13.44 / 15.72 | 10143.5 | 7529.5 | 219.2 | 98/100 | -0.02113 / 0.02290 |
| TK2 | M1 + compensation | down from top | 10.37 / 14.68 / 15.89 | 426021.0 | 81892.0 | 544.3 | 9/100 | -0.02634 / 0.03750 |
| TK2 | M1 + compensation | up from end | 9.79 / 14.05 / 15.66 | 17592.5 | -596.5 | 277.8 | 97/100 | -0.03663 / 0.03566 |
| TK2 | M0 NO styling at all | down from top | 2.94 / 3.30 / 3.52 | 365116.0 | 86620.5 | 0.0 | 0/100 | -0.02814 / 0.04783 |
| TK2 | M0 NO styling at all | up from end | 3.30 / 4.14 / 6.47 | 4722.0 | 10499.5 | 0.0 | 0/100 | -0.01271 / -0.00047 |

#### scroll steps, corpus 5m (4986175 UTF-16 units); step = 350 pt (half a page); lazily style visible +/- 60 lines each step
| engine | mitigation | scenario | step ms med / p95 / max | max |ΔH| per step (pt) | H drift over session (pt) | max visual jump (pt) | steps with jump > 0.5 pt | thumb Δ min / max per step |
|---|---|---|---|---|---|---|---|---|
| TK1-noncontig | M0 natural heights | down from top | 7.98 / 9.01 / 10.41 | 332.0 | 16469.0 | 26.0 | 11/100 | 0.00029 / 0.00033 |
| TK1-noncontig | M0 natural heights | up from end | 8.11 / 9.43 / 10.45 | 524.0 | 16484.5 | 22.0 | 11/100 | -0.00034 / -0.00024 |
| TK1-noncontig | M0 + styled-range cache | down from top | 4.00 / 4.98 / 5.34 | 436.0 | 16087.0 | 0.0 | 0/100 | 0.00031 / 0.00032 |
| TK1-noncontig | M0 + styled-range cache | up from end | 5.11 / 6.46 / 9.69 | 524.0 | 16636.5 | 22.0 | 11/100 | -0.00034 / -0.00030 |
| TK1-noncontig | M1 uniform heights | down from top | 7.66 / 9.44 / 11.88 | 560.0 | 18903.0 | 0.0 | 0/100 | 0.00025 / 0.00032 |
| TK1-noncontig | M1 uniform heights | up from end | 7.50 / 8.76 / 9.44 | 590.5 | 19133.5 | 28.0 | 5/100 | -0.00034 / -0.00030 |
| TK1-noncontig | M1 + styled-range cache | down from top | 3.50 / 5.02 / 9.45 | 539.0 | 19078.0 | 0.0 | 0/100 | 0.00030 / 0.00032 |
| TK1-noncontig | M1 + styled-range cache | up from end | 4.85 / 8.57 / 11.55 | 671.0 | 19084.5 | 28.0 | 1/100 | -0.00034 / -0.00030 |
| TK1-noncontig | M0 + anchor compensation | down from top | 7.73 / 8.46 / 16.12 | 408.0 | 16589.0 | 40.0 | 33/100 | 0.00028 / 0.00034 |
| TK1-noncontig | M0 + anchor compensation | up from end | 8.01 / 9.26 / 11.20 | 416.0 | 11042.5 | 414.0 | 95/100 | -0.00035 / 0.00006 |
| TK1-noncontig | M1 + compensation | down from top | 7.55 / 8.54 / 8.94 | 606.0 | 18606.0 | 98.0 | 38/100 | 0.00018 / 0.00033 |
| TK1-noncontig | M1 + compensation | up from end | 7.19 / 8.62 / 11.42 | 539.0 | 12235.0 | 502.5 | 88/100 | -0.00036 / 0.00017 |
| TK1-noncontig | M0 NO styling at all | down from top | 1.33 / 1.70 / 2.19 | 456.0 | 16497.0 | 0.0 | 0/100 | 0.00031 / 0.00032 |
| TK1-noncontig | M0 NO styling at all | up from end | 1.65 / 2.02 / 2.16 | 556.0 | 16958.5 | 0.3 | 0/100 | -0.00032 / -0.00030 |
| TK2 | M0 natural heights | down from top | 8.81 / 10.04 / 14.65 | 1521859.0 | 154192.5 | 166.8 | 98/100 | -0.00522 / 0.00673 |
| TK2 | M0 natural heights | up from end | 9.11 / 12.26 / 14.34 | 17961.5 | 2229.5 | 194.2 | 79/100 | -0.00814 / 0.00945 |
| TK2 | M0 + styled-range cache | down from top | 5.83 / 6.77 / 7.15 | 1919734.5 | 232472.5 | 350.0 | 1/100 | -0.00535 / 0.00901 |
| TK2 | M0 + styled-range cache | up from end | 6.30 / 7.87 / 10.85 | 234.5 | 4649.5 | 6.0 | 1/100 | -0.00030 / -0.00007 |
| TK2 | M1 uniform heights | down from top | 7.81 / 8.93 / 9.53 | 2033926.5 | 966447.0 | 166.7 | 99/100 | -0.00562 / 0.00531 |
| TK2 | M1 uniform heights | up from end | 8.33 / 9.50 / 11.61 | 12041.5 | 432.5 | 227.9 | 80/100 | -0.00405 / 0.00531 |
| TK2 | M1 + styled-range cache | down from top | 5.17 / 6.13 / 6.70 | 2443237.5 | 1811306.0 | 0.0 | 0/100 | -0.00526 / 0.00877 |
| TK2 | M1 + styled-range cache | up from end | 6.30 / 9.05 / 12.04 | 194.5 | 5090.5 | 0.0 | 0/100 | -0.00025 / -0.00007 |
| TK2 | M0 + anchor compensation | down from top | 9.64 / 10.87 / 13.85 | 1888287.5 | 101952.0 | 537.9 | 4/100 | -0.00499 / 0.00572 |
| TK2 | M0 + anchor compensation | up from end | 9.71 / 10.95 / 15.40 | 16290.5 | 2926.0 | 245.6 | 97/100 | -0.00583 / 0.00854 |
| TK2 | M1 + compensation | down from top | 8.68 / 9.68 / 10.44 | 2189247.0 | 431417.0 | 544.3 | 9/100 | -0.00570 / 0.00797 |
| TK2 | M1 + compensation | up from end | 8.97 / 10.18 / 15.73 | 12154.5 | 18236.0 | 259.3 | 96/100 | -0.00383 / 0.00539 |
| TK2 | M0 NO styling at all | down from top | 2.91 / 3.11 / 3.54 | 1950164.5 | 443437.0 | 0.0 | 0/100 | -0.00592 / 0.01008 |
| TK2 | M0 NO styling at all | up from end | 3.23 / 3.81 / 7.03 | 957.5 | 5683.0 | 0.0 | 0/100 | -0.00031 / 0.00040 |

#### scroll steps, corpus 20m (19942150 UTF-16 units); step = 350 pt (half a page); lazily style visible +/- 60 lines each step
| engine | mitigation | scenario | step ms med / p95 / max | max |ΔH| per step (pt) | H drift over session (pt) | max visual jump (pt) | steps with jump > 0.5 pt | thumb Δ min / max per step |
|---|---|---|---|---|---|---|---|---|
| TK1-noncontig | M0 natural heights | down from top | 7.82 / 8.83 / 10.78 | 332.0 | 16469.0 | 26.0 | 11/100 | 0.00007 / 0.00008 |
| TK1-noncontig | M0 natural heights | up from end | 8.37 / 9.94 / 13.09 | 538.0 | 16096.0 | 40.0 | 13/100 | -0.00009 / -0.00006 |
| TK1-noncontig | M0 + styled-range cache | down from top | 4.01 / 5.17 / 9.16 | 436.0 | 16087.0 | 0.0 | 0/100 | 0.00008 / 0.00008 |
| TK1-noncontig | M0 + styled-range cache | up from end | 5.17 / 6.21 / 8.07 | 538.0 | 16352.0 | 40.0 | 13/100 | -0.00009 / -0.00008 |
| TK1-noncontig | M1 uniform heights | down from top | 7.55 / 8.42 / 10.99 | 546.0 | 18903.0 | 0.0 | 0/100 | 0.00006 / 0.00008 |
| TK1-noncontig | M1 uniform heights | up from end | 7.49 / 9.00 / 10.05 | 816.0 | 19067.0 | 28.0 | 6/100 | -0.00009 / -0.00008 |
| TK1-noncontig | M1 + styled-range cache | down from top | 3.45 / 5.01 / 7.59 | 539.0 | 19078.0 | 0.0 | 0/100 | 0.00008 / 0.00008 |
| TK1-noncontig | M1 + styled-range cache | up from end | 4.55 / 5.87 / 6.18 | 616.0 | 18864.0 | 35.0 | 5/100 | -0.00009 / -0.00008 |
| TK1-noncontig | M0 + anchor compensation | down from top | 7.83 / 9.18 / 10.42 | 408.0 | 16589.0 | 40.0 | 33/100 | 0.00007 / 0.00008 |
| TK1-noncontig | M0 + anchor compensation | up from end | 8.01 / 9.35 / 9.64 | 476.0 | 10899.5 | 474.5 | 93/100 | -0.00009 / 0.00003 |
| TK1-noncontig | M1 + compensation | down from top | 7.55 / 8.41 / 10.87 | 606.0 | 18606.0 | 98.0 | 38/100 | 0.00004 / 0.00008 |
| TK1-noncontig | M1 + compensation | up from end | 7.17 / 9.04 / 13.02 | 616.0 | 12181.0 | 518.0 | 71/100 | -0.00010 / 0.00006 |
| TK1-noncontig | M0 NO styling at all | down from top | 1.32 / 1.69 / 2.20 | 456.0 | 16497.0 | 0.0 | 0/100 | 0.00008 / 0.00008 |
| TK1-noncontig | M0 NO styling at all | up from end | 1.65 / 1.95 / 2.26 | 476.0 | 16604.0 | 0.3 | 0/100 | -0.00008 / -0.00008 |
| TK2 | M0 natural heights | down from top | 8.65 / 9.81 / 13.30 | 6158786.5 | 624387.5 | 166.8 | 98/100 | -0.00132 / 0.00170 |
| TK2 | M0 natural heights | up from end | 8.96 / 10.21 / 11.33 | 21862.5 | -758.0 | 306.9 | 78/100 | -0.00230 / 0.00294 |
| TK2 | M0 + styled-range cache | down from top | 5.79 / 6.65 / 9.22 | 7768975.5 | 932420.5 | 350.0 | 1/100 | -0.00135 / 0.00227 |
| TK2 | M0 + styled-range cache | up from end | 6.26 / 7.80 / 9.86 | 11414.0 | 16006.5 | 2.0 | 1/100 | -0.00159 / -0.00003 |
| TK2 | M1 uniform heights | down from top | 7.89 / 8.88 / 9.58 | 8216039.5 | 3908095.0 | 166.7 | 99/100 | -0.00142 / 0.00134 |
| TK2 | M1 uniform heights | up from end | 8.30 / 9.46 / 12.99 | 10982.5 | 3052.5 | 407.6 | 81/100 | -0.00123 / 0.00124 |
| TK2 | M1 + styled-range cache | down from top | 5.26 / 6.20 / 11.45 | 9869082.0 | 7317702.5 | 0.0 | 0/100 | -0.00132 / 0.00221 |
| TK2 | M1 + styled-range cache | up from end | 6.02 / 7.52 / 11.93 | 305.0 | 5151.0 | 0.0 | 0/100 | -0.00006 / -0.00001 |
| TK2 | M0 + anchor compensation | down from top | 9.65 / 11.13 / 13.34 | 7627789.0 | 412116.5 | 537.9 | 4/100 | -0.00126 / 0.00144 |
| TK2 | M0 + anchor compensation | up from end | 10.12 / 11.74 / 17.84 | 13878.5 | 89.5 | 332.8 | 98/100 | -0.00191 / 0.00166 |
| TK2 | M1 + compensation | down from top | 8.65 / 9.87 / 10.63 | 8799214.0 | 1741712.0 | 544.3 | 9/100 | -0.00145 / 0.00202 |
| TK2 | M1 + compensation | up from end | 9.18 / 11.85 / 13.61 | 15708.0 | 1211.0 | 276.4 | 95/100 | -0.00149 / 0.00177 |
| TK2 | M0 NO styling at all | down from top | 2.97 / 3.17 / 3.52 | 7892183.0 | 1781066.5 | 0.0 | 0/100 | -0.00149 / 0.00254 |
| TK2 | M0 NO styling at all | up from end | 3.28 / 3.92 / 6.65 | 17483.0 | 24014.0 | 0.0 | 0/100 | -0.00250 / 0.00000 |

