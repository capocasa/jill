
import jill, jacket

iterator read*(buffer: MidiBuffer): MidiEvent =
  var event: MidiEvent = cast[MidiEvent](alloc(sizeof(MidiEventT)))
  let eventCount = midiGetEventCount(buffer)
  for i in 0.cint ..< eventCount.cint:
    assert 0 == midiEventGet(event, buffer, i.uint32)
    yield event

template send*(buffer: var MidiBuffer, time: Nframes, size: int, body: untyped) =
  let dataArray = cast[ptr UncheckedArray[byte]](midiEventReserve(buffer, time, size.csize_t))
  proc sendImpl(data {.inject.}: var openArray[byte]) =
    body
  sendImpl(dataArray.toOpenArray(0, size-1))

proc send*(buffer: var MidiBuffer, time: Nframes, indata: openArray[byte]) =
  let dataArray = midiEventReserve(buffer, time, indata.len.csize_t)
  copyMem(dataArray, indata[0].addr, indata.len)

