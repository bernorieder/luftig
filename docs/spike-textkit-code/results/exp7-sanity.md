### 7a. IME composition (marked text, attributed like a real IME) vs attribute application
| engine | restyle policy | after setMarkedText("n"): markedRange / attribute keys on marked text | underline / clause-segment attributes found in the text storage during composition? | hasMarkedText sequence over 3 compositions steps | final string correct after commit | marked attrs at commit |
|---|---|---|---|---|---|---|
| TK1-noncontig | no restyle | 5+1 / `Color,Font,ParagraphStyle` | no: marked-text decoration is not stored in the storage (keys `Color,Font,ParagraphStyle`) | TTTF | yes | `Color,Font,ParagraphStyle` |
| TK1-noncontig | restyle during composition (setAttributes, no guard) | 5+1 / `Color,Font,ParagraphStyle` | no: marked-text decoration is not stored in the storage (keys `Color,Font,ParagraphStyle`) | TTTF | yes | `Color,Font,ParagraphStyle` |
| TK1-noncontig | guard: skip while hasMarkedText(), restyle at commit | 5+1 / `Color,Font,ParagraphStyle` | no: marked-text decoration is not stored in the storage (keys `Color,Font,ParagraphStyle`) | TTTF | yes | `Color,Font,ParagraphStyle` |
| TK2 | no restyle | 5+1 / `Color,Font,ParagraphStyle` | no: marked-text decoration is not stored in the storage (keys `Color,Font,ParagraphStyle`) | TTTF | yes | `Color,Font,ParagraphStyle` |
| TK2 | restyle during composition (setAttributes, no guard) | 5+1 / `Color,Font,ParagraphStyle` | no: marked-text decoration is not stored in the storage (keys `Color,Font,ParagraphStyle`) | TTTF | yes | `Color,Font,ParagraphStyle` |
| TK2 | guard: skip while hasMarkedText(), restyle at commit | 5+1 / `Color,Font,ParagraphStyle` | no: marked-text decoration is not stored in the storage (keys `Color,Font,ParagraphStyle`) | TTTF | yes | `Color,Font,ParagraphStyle` |

### 7b. restyle made inside textStorage(_:didProcessEditing:) is picked up by layout (typing '# ' at the start of a plain line)
| engine | line height before | after '#' | after '# ' (heading) | font size at line start after '# ' |
|---|---|---|---|---|
| TK1-noncontig | 18.0 | 18.0 | 30.0 | 26.0 |
| TK2 | 18.0 | 18.0 | 30.0 | 26.0 |

### 7c. undo stack vs attribute-only changes
| engine | step | canUndo | levels undone to reach empty | note |
|---|---|---|---|---|
| TK1-noncontig | restyle whole doc with setAttributes (begin/endEditing) | false | - | attribute-only changes must not register undo |
| TK1-noncontig | type X, (event loop turn), type Y, then undo until empty | false | 1 | text after typing began "HelloXY ..."; fully reverted to original: true |
| TK1-noncontig | redo all | canUndo=true | 1 | text restored: true; heading font still 26.0 pt |
| TK1-noncontig | textView.string = ... after an edit (reload) | canUndo true -> true | - | call undoManager.removeAllActions() yourself on reload |
| TK2 | restyle whole doc with setAttributes (begin/endEditing) | false | - | attribute-only changes must not register undo |
| TK2 | type X, (event loop turn), type Y, then undo until empty | false | 1 | text after typing began "HelloXY ..."; fully reverted to original: true |
| TK2 | redo all | canUndo=true | 1 | text restored: true; heading font still 26.0 pt |
| TK2 | textView.string = ... after an edit (reload) | canUndo true -> true | - | call undoManager.removeAllActions() yourself on reload |

### 7d. storage delegate ownership
- TK1-noncontig: textStorage.delegate by default = nil; our HighlightController installed fine and was called (see 7b: heading height changed)
- TK2: textStorage.delegate by default = nil; our HighlightController installed fine and was called (see 7b: heading height changed)

### 7e. accessibility queries VoiceOver makes (ms)
| corpus | engine | numberOfCharacters | visibleCharacterRange | accessibilityValue (whole text) | string(for: 1 line) | line(for: mid) | selectedTextRange |
|---|---|---|---|---|---|---|---|
| 1m | TK1-noncontig | 0.00 (n=997320) | 0.00 (0+1598) | 0.00 | 0.14 | 164.52 | 0.01 |
| 1m | TK2 | 0.00 (n=997320) | 0.00 (0+1598) | 0.00 | 0.00 | 198.41 | 0.01 |
| 20m | TK1-noncontig | 0.00 (n=19942150) | 0.00 (0+1598) | 0.00 | 0.01 | 3277.70 | 0.01 |
| 20m | TK2 | 0.00 (n=19942150) | 0.00 (0+1598) | 0.00 | 0.01 | 4238.03 | 0.01 |
