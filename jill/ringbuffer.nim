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

proc push*[T](b: var RingBuffer[T], x: T) =
  discard ringbufferWrite(b.handle, cast[cstring](x.addr), csize_t sizeof T)

proc pop*[T](b: var RingBuffer[T], x: var T) =
  discard ringbufferRead(b.handle, cast[cstring](x.addr), csize_t sizeof T)

proc pop*[T](b: var RingBuffer[T]): T =
  discard ringbufferRead(b.handle, cast[cstring](result.addr), csize_t sizeof T)

proc push*[T](b: var RingBuffer[T], x: openArray[T]) =
  discard ringbufferWrite(b.handle, cast[cstring](x.addr), csize_t(x.len * sizeof T))

proc pop*[T](b: var RingBuffer[T], x: var openArray[T]) =
  discard ringbufferRead(b.handle, cast[cstring](x.addr), csize_t(x.len * sizeof T))

proc pop*[T](b: var RingBuffer[T], len: int): seq[T] =
  result = newSeq[T](len)
  discard ringbufferRead(b.handle, cast[cstring](result[0].addr), csize_t(len * sizeof T))

