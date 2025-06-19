Jill
====

Jill is a Nimish high-level interface to the Jack Audio Connection Kit.

It is built up as a single macro- `withJack` (and that's where the name comes from, because who is with jack if not Jill?). The macro encapsulates a full jack implementation, and you only provide your inputs and outputs.

Basic usage
-----------

You use the `withjack` macro and pass a tuple with the inputs you want, and/or one with the outputs.

Each input and output will be available as a variable in the body, just like the result variable is automatically available in a Nim proc.

There are also a few basic variables available- `sampleRate`, `sampleDuration` (the inverse of sampleRate), and the buffer size as the length of the inputs and outputs.

Oscillator
----------

Very simple pulse oscillator at the frequency of the jack period.

Be careful, it's not bandlimited, play back quietly

```nim
import jill

withJack output=(left, right):
  for i in 0..left.len:
    left[i] = if i < left.len div 2: -0.5 else: 0.5
    right[i] = left[i]
```

Mixer
-----

This is a simple app to illustrate inputs and outputs. It mixes the signals together.

```nim
import jill
withJack input=(c1, c2, c3, c4), output=(o):
  for i in 0..o.len:
    o[i] = c1[i] + c2[i] + c3[i] + c4[i]
```

Echo
----

The `withJack` block acts as a closure, so you can access data from before to have state. Here is a simple delay line.

```nim
import jill
withJack input=sig, output=del:
  for i in 0..sig.len:
    del[i] = sig[i] + (if i < b.len: 0.5 * b[i] else: sig[i-b.len])
  for i in 0..b.len-1:
    b[i] = sig[sig.len - b.len + i]
```

Complete call
-------------

This does nothing, but demonstrates all the `withJack` parameters.

```nim
import jill
withJack input=a, output=b, clientName="myJackClient", mainApp=false:
  discard
```

Positional works too

```nim
withJack a, b, "myJackClient", false:
  discard
```nim

- *input* is a list of float32 openArray variables that will be available in the code block as inputs
- *output* same with outputs
- *clientName* a string that will be jack client name, defaults to `defaultClientName()` which returns the
  filename of the ececutable without extension. So if you run your program as `./foo.app` the client name will be `foo`.
- *mainApp* a boolean that defauls to true. If it is set, `withJack` will set up a complete jack application including
  a main loop that just sleeps, and handlers to quit the program if jack shuts down or a signal is received. If you
  want your own main loop and use it as part of a larger application, you can set this to false and handle things yourself.

```nim
withJack a, b, "myJackClient", false:
  discard

# signal handler code here
# Use `jacket` to register more jack callbacks here

while true:
  sleep(high(int))

```

This does nothing, but demonstrates all the `withJack` parameters.

```nim
import jill
withJack input=a, output=b, clientName="myJackClient", mainApp=false:
  discard
```

Positional works too

```nim
withJack a, b, "myJackClient", false:
  discard
```nim

- *input* is a list of float32 openArray variables that will be available in the code block as inputs
- *output* same with outputs
- *clientName* a string that will be jack client name, defaults to `defaultClientName()` which returns the
  filename of the ececutable without extension. So if you run your program as `./foo.app` the client name will be `foo`.
- *mainApp* a boolean that defauls to true. If it is set, `withJack` will set up a complete jack application including
  a main loop that just sleeps, and handlers to quit the program if jack shuts down or a signal is received. If you
  want your own main loop and use it as part of a larger application, you can set this to false and handle things yourself.

```nim
withJack a, b, "myJackClient", false:
  discard

# signal handler code here
# Use `jacket` to register more jack callbacks here

while true:
  sleep(high(int))

```

Ring buffer
-----------

For thread communication, jill provides a Nimish wrap of the jack ring buffer. You can add elements in one thread and remove them in another, without locks.

```nim
import jill/ringbuffer

var b = newRingBuffer[float32](1024)

b.push(1.0)                  # buffer contains [1.0]
echo $b.pop()                # 1.0, buffer is empty
b.push(1.0)                  # buffer contains [1.0]
var x:float32                # pre-existing variable to pop into
b.pop(x)                     # buffer is empty
echo $x                      # 1.0

b.push([1.0'f32,2.0'f32])    # buffer contains [1.0, 2.0]
echo $b.pop(2)               # @[1.0, 2.0, buffer is empty
var s = newSeq[float32](2)   # pre-existing seq to pop into
b.pop(s)                     # buffer is empty
echo $s                      # @[1.0, 2.0]

# cleanup is done by Nim

```

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
- Mid-level API (as opposed to the `withJack` high level API), Nimish fully flexible Jack API
- float64 support
- MIDI
- Multithreading
- Connections

Changelog
---------

```
0.2.1  Expose jack client, ringbuffer iteration
0.2.0  Add jack ringbuffer
0.1.0  Inital release
```

Thank you!
----------

Thank you for your interest!

