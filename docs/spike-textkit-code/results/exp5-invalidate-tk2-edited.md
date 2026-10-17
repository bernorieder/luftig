theme: natural line heights (M0)
| engine | case | widen invalidation | neighbour touch | invalidated rects after the change (rows) | required region covered | TK2: paragraph offsets with re-created fragments |
|---|---|---|---|---|---|---|
| TK2 | grow: line below the block becomes code | - | no | FULL(infinite) FULL(infinite) (required y 496.0..520.0, x 19.0..701.0) | n/a (per-fragment layers) | 1197,1198 |
| TK2 | grow: line below the block becomes code | - | yes | FULL(infinite) FULL(infinite) (required y 496.0..520.0, x 19.0..701.0) | n/a (per-fragment layers) | 1193,1197,1198 |
| TK2 | shrink: last body line + closing fence become prose | - | no | FULL(infinite) FULL(infinite) (required y 464.0..502.0, x 19.0..701.0) | n/a (per-fragment layers) | 1140,1193,1197 |
| TK2 | shrink: last body line + closing fence become prose | - | yes | FULL(infinite) FULL(infinite) (required y 464.0..502.0, x 19.0..701.0) | n/a (per-fragment layers) | 1084,1140,1193,1197 |
(offsets: block closing fence = 1193, last body line = 1140, line before that = 1084, line below the block = 1197)
