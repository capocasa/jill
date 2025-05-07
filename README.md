Jill
====

Jill is a Nimish Nim interface to the Jack Audio Connection Kit.

Here's how it works:

```
import jill, comus/instr, comus/fx


# initialize
let n = 64, rate = 48000

let vocoder = newVocoder()
let saw = Saw()
var voice = newSeqOfCap[float](n)

withJack in=(ribbon, vocal), out=(left, right):
  # control rate
  for freq in [ribbon, ribbon * 1.5, ribbon * 2]:
    # audio rate
    for i in 0..n:
      saw.process(freq)
  for i in 0..n:
    ribbon[i] = vocoder.process(vocal[i], ribbon[i])

```

FAQ
---

*Q: Is Jill another clever project name?*

A: Yes, I couldn't help myself.

*Q: Okay, why?*

A: Because Jill is... with jack, of course.

