import jacket

type
  RingBuffer*[T] = object
    handle*: jacket.RingBuffer

proc newRingBuffer*[T](size: Natural): RingBuffer[T] =
  result.handle = ringbufferCreate(csize_t(size * sizeof T))

proc `=destroy`[T](b: var RingBuffer[T]) =
  if not b.handle.isNil:
    ringbufferFree(b.handle)

proc `=wasMoved`[T](b: var RingBuffer[T]) =
  b.handle = nil

proc `=sink`[T](dest: var RingBuffer[T]; src: RingBuffer[T]) =
  dest.handle = src.handle

# TODO: don't do checks when defined(danger) is on

proc push*[T](b: var RingBuffer[T], x: T) =
  if ringbufferWrite(b.handle, cast[cstring](x.addr), csize_t sizeof T) != csize_t sizeof T:
    raise newException(IndexDefect, "Could not write to ring buffer")

proc pop*[T](b: var RingBuffer[T], x: var T): bool =
  ringbufferRead(b.handle, cast[cstring](x.addr), csize_t sizeof T) == csize_t sizeof T

proc pop*[T](b: var RingBuffer[T]): T =
  if ringbufferRead(b.handle, cast[cstring](result.addr), csize_t sizeof T) != csize_t sizeof T:
    raise newException(IndexDefect, "Could not read from ring buffer")

proc peek*[T](b: RingBuffer[T], x: var T): bool =
  ringbufferPeek(b.handle, cast[cstring](x.addr), csize_t sizeof T) == csize_t sizeof T

proc peek*[T](b: RingBuffer[T]): T =
  if ringbufferPeek(b.handle, cast[cstring](result.addr), csize_t sizeof T) != csize_t sizeof T:
    raise newException(IndexDefect, "Could not peek from ring buffer")

proc push*[T](b: var RingBuffer[T], x: openArray[T]) =
  if ringbufferWrite(b.handle, cast[cstring](x.addr), csize_t(x.len * sizeof T)) != csize_t(x.len * sizeof T):
    raise newException(IndexDefect, "Could not write to ring buffer")

proc pop*[T](b: var RingBuffer[T], x: var openArray[T]) =
  ringbufferRead(b.handle, cast[cstring](x.addr), csize_t(x.len * sizeof T)) div csize_t(sizeof T)

proc pop*[T](b: var RingBuffer[T], len: int): seq[T] =
  result = newSeq[T](len)
  if ringbufferRead(b.handle, cast[cstring](result[0].addr), csize_t(len * sizeof T)) != csize_t(len * sizeof T):
    raise newException(IndexDefect, "Could not read from ring buffer")

proc peek*[T](b: RingBuffer[T], x: var openArray[T]) =
  int (ringbufferPeek(b.handle, cast[cstring](x.addr), csize_t(x.len * sizeof T)) div csize_t(sizeof T))

# TODO: have a peekAll based on len

proc peek*[T](b: RingBuffer[T], len: int): seq[T] =
  result = newSeq[T](len)
  if ringbufferPeek(b.handle, cast[cstring](result[0].addr), csize_t(len * sizeof T)) != csize_t(len * sizeof T):
    raise newException(IndexDefect, "Could not peek from ring buffer")

proc readAdvance*[T](b: var RingBuffer[T], n: int = 1) =
  ringbufferReadAdvance(b.handle, csize_t (n * sizeof T))

proc writeAdvance*[T](b: var RingBuffer[T], n: int = 1) =
  ringbufferWriteAdvance(b.handle, csize_t (n * sizeof T))

proc len*[T](b: var RingBuffer[T]): int =
  b.handle.ringbufferReadSpace().int div sizeof T

iterator pop*[T](b: var RingBuffer[T]): T =
  ## Iterate over all data in the ringbuffer
  ## The item is consumed after the iteration is complete
  ## so if there is an error or a break from the loop,
  ## the data item is *not* consumed.
  var item: T
  for i in 0 ..< b.len:
    if ringbufferPeek(b.handle, cast[cstring](item.addr), csize_t sizeof T) != csize_t sizeof T:
      raise newException(IndexDefect, "Could not peek from ring buffer")
    yield item
    ringbufferReadAdvance(b.handle, csize_t sizeof T)

#[

# I wonder I couldn't get this to work.
# readVectorRaw.len responds 318 instead of the correct sizeof T (10)
# casting is correct
# weird

iterator vector*[T](b: RingBuffer[T]): lent T =
  # zero copy iteration over ring buffer contents
  var
    item: ptr T
    readVectorRaw: RingbufferData
    readVector: ptr array[2, RingbufferDataT]
  b.handle.ringbufferGetReadvector(readVectorRaw)
  echo (readVectorRaw.len, readVectorRaw.buf.isNil, b.handle.ringBufferReadSpace(), sizeof T)
  if not readVectorRaw.buf.isNil:
    var e = cast[ptr T](readVectorRaw.buf)
    echo $e[]
  readVector = cast[ptr array[2, RingbufferDataT]](readVectorRaw)
  for readSlice in readVector[]:
    for j in countup(0, pred readSlice.len.int, sizeof T):
      echo readSlice
      item = cast[ptr T](readSlice.buf)
      yield item[]
]#

proc lock*(b: RingBuffer) =
  b.handle.ringbufferMlock()

