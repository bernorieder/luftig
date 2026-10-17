
#### scroll steps, corpus 20k (20189 UTF-16 units); step = 350 pt (half a page); lazily style visible +/- 60 lines each step
| engine | mitigation | scenario | step ms med / p95 / max | max |ΔH| per step (pt) | H drift over session (pt) | max visual jump (pt) | steps with jump > 0.5 pt | thumb Δ min / max per step |
|---|---|---|---|---|---|---|---|---|
| TK1-noncontig | M0 NO styling at all | down from top | 1.52 / 1.88 / 3.00 | 358.0 | 3196.0 | 0.0 | 0/20 | 0.01662 / 0.08145 |
| TK1-noncontig | M0 NO styling at all | up from end | 1.45 / 1.85 / 1.85 | 288.0 | 1970.0 | 0.0 | 0/20 | -0.06019 / -0.02078 |
| TK1-noncontig | M1 + styled-range cache | down from top | 3.49 / 5.11 / 5.33 | 462.0 | 3654.0 | 0.0 | 0/20 | 0.00648 / 0.07793 |
| TK1-noncontig | M1 + styled-range cache | up from end | 4.28 / 5.37 / 5.50 | 504.0 | 2744.0 | 28.0 | 1/20 | -0.05606 / -0.00063 |
| TK2 | M0 NO styling at all | down from top | 2.95 / 3.19 / 3.22 | 1423.0 | 984.0 | 0.0 | 0/20 | -0.01104 / 0.10685 |
| TK2 | M0 NO styling at all | up from end | 3.02 / 3.29 / 3.33 | 173.5 | 985.0 | 0.0 | 0/20 | -0.06702 / -0.02562 |
| TK2 | M1 + styled-range cache | down from top | 5.91 / 6.90 / 6.98 | 1777.5 | 872.5 | 0.0 | 0/20 | -0.01108 / 0.08959 |
| TK2 | M1 + styled-range cache | up from end | 5.26 / 6.33 / 6.43 | 127.0 | 770.5 | 0.0 | 0/20 | -0.04670 / -0.02567 |
