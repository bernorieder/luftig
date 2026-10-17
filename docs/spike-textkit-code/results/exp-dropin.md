### drop-in stack (ScribeEditorFactory + LazyStyler + ReadableColumnController + ScribeLayoutManager), corpus 20m, uniform line heights

A. open (median of runs 2..7; cold = run 1 total 42.3 ms): string= + base attrs 16.3 | style first screen (331 runs) 2.3 | layout 0.0 | draw 4.0 | **total 22.6 ms** [min 22.3 max 23.5]
B. down from top: step ms med 3.43 / p95 4.91 / max 13.35; steps with visual jump > 0.5 pt: 0/100 (max 0.0 pt); thumb Δ per step min/max 0.00008 / 0.00008; styleVisible() fast path when nothing to do: 0.0015 ms
B. up from end: step ms med 3.92 / p95 5.71 / max 6.72; steps with visual jump > 0.5 pt: 3/100 (max 28.0 pt); thumb Δ per step min/max -0.00009 / -0.00008; styleVisible() fast path when nothing to do: 0.0016 ms
C. Cmd-Down (styler.scroll(toCharacter: end)): 14.6 ms; landing shift after further layout/styling passes 0.0 pt; top char fraction 0.9999; thumb 1.0000; at bottom true; fence pre-scan (first jump only) 9.1 ms
C. jump to middle: 116.6 ms; landing shift after further layout/styling passes 0.0 pt; top char fraction 0.5000; thumb 0.5003; at bottom false; fence pre-scan (first jump only) 9.5 ms
C. jump to 25 %: 61.6 ms; landing shift after further layout/styling passes 0.0 pt; top char fraction 0.2500; thumb 0.2504; at bottom false; fence pre-scan (first jump only) 8.8 ms
C. jump to 75 %: 60.5 ms; landing shift after further layout/styling passes 0.0 pt; top char fraction 0.7499; thumb 0.7500; at bottom false; fence pre-scan (first jump only) 8.8 ms
D. typing at the middle of 20m through LazyStyler.didProcessEditing: total 3.72 ms (p95 3.89), insertText incl. restyle 0.91 ms
   undo: 1 level(s) to revert 60 typed characters; styled-set ranges after edits: 1
E. IME: styleVisible() during composition applied 0 runs (expected 0), hasMarkedText true -> false, final text starts with "Hello你 w"
F. resize 900 -> 600 in the middle of 20m with ReadableColumnController: step med 11.36 ms, p95 11.91 ms; top char fraction 0.49997 -> 0.49997; inset now 28.0
