Jill
====

Jill is a high-level interface to the Jack Audio Connection Kit.

It is built up as a single macro- `withJack` (and that's where the name comes from, because who is with jack if not Jill?). The macro encapsulates a full jack implementation, and you only provide your inputs and outputs.

Basic usage
-----------

You use the `withjack` macro and pass a tuple with the inputs you want, and/or one with the outputs.

Each input and output will be available as a variable in the body, just like the result variable is automatically available in a Nim proc.

There are also a few basic variables available- `sampleRate`, `sampleDuration` (the inverse of sampleRate), and the buffer size as the length of the inputs and outputs.

Oscillator
----------

```
import jill

var c = 0

withJack output=(left, right):
  c += 5 * sampleDuration
  if c > 2000 / 48000:
    c = 50 * sampleDuration
  for i in 0 .. (left.len div 2) - 1:
    left[i] = i.float32 * (1/bufferSize)
    right[i] = left[i]
```

Mixer
-----

This is a simple app to illustrate inputs and outputs. It mixes the signals together.

withJack input=(c1, c2, c3, c4) output=out:
  for i in bufferSize:
    out[i] = c1[i] + c2[i] + c3[i] + c4[i]

Echo
----

The withjack block acts as a closure, so you can access data from before to have state. Here is a simple delay line.

var buffer = newSeq[float32](27)

withJack input=someSignal out=withEcho:
  for i in input.len:
    withEcho[i] = someSignal[i] + if i < buffer.len: 0.5 * buffer[i] else: someSignal[i-buffer.len]
  for i in 0..buffer.len-1:
    buffer[i] = someSignal[someSignal.len - buffer.len + i]


Design
------

Jill is meant for the most common jack use case, fixed inputs and outputs. It is assumed that if you need 20 inputs, you can define them at compile time. This also makes it easiest for session managers to pick up on your application. If you need to add and remove inputs at runtime, at the moment you should use the excellent `jacket` library that jill is based on directly.

Internally, Jill implements a full jack client in a macro and generates a Nim wrapper procedure that acts as a closure to be called by the Jack C callback. The inputs are passed as `openArray[float32]`, and the outputs are `var openArray[float32]`, which is a type of a so called unowned view. This way you can access the jack data from C without copying it and you still get Nim's bounds checking and you can't accidentally write to an input.

Multiprocessing
---------------

jill does not support multiprocessing by itself. It is recommended to use jack2, and split your application into several `withJack` calls where there are components that can be run independently.

Roadmap
-------

This first version is limited in scope on purpose. There is interest in eventually supporting more flexible use cases as well.

- Dynamically added inputs and outputs at runtime
- Groups of inputs and outputs
- Support for more jack callbacks
- float64 support
- MIDI
- Multithreading
- Connections

Thank you!
----------

Thank you for your interest!

