import std/[unittest,math]
import tests/mock_jacket as jacket
import ../jill
import ../jill/midi

suite "Jill":

  setup:
    jacket.resetMocks()

  teardown:
    jacket.resetMocks()

  test "one cycle of stereo audio input and output":
    var
      testee1In1, testee1In2: array[64, float32]

    # Test the withJack macro - this generates the same code as the original test
    withJack audioOut=(out1, out2), audioIn=(in1, in2), mainApp=false, clientName="testee1":
      for i in 0..in1.len-1:
        testee1In1[i] = in1[i]
        testee1In2[i] = in2[i]

        # Different test signal from testee
        out1[i] = i.float32 * 0.001
        out2[i] = 1 - i.float32 * 0.001

    # The withJack macro should have created:
    # - client with name "testee1" 
    # - ports: out1Port, out2Port, in1Port, in2Port
    # - process callback that calls the block above
    # - activation of the client

    # Set up input data for the process callback to receive
    var in1TestData = newSeq[float32](64)
    var in2TestData = newSeq[float32](64)
    for i in 0..<64:
      in1TestData[i] = i.float32 * 0.01
      in2TestData[i] = 1.0 - i.float32 * 0.01

    # Inject test data into the input ports that withJack created
    jacket.setMockPortData(cast[jacket.Port](3), in1TestData)  # in1Port is likely port ID 3
    jacket.setMockPortData(cast[jacket.Port](4), in2TestData)  # in2Port is likely port ID 4

    # Trigger the process callback that withJack set up
    discard jacket.simulateProcessCycle(64)

    # Verify the macro-generated code processed the data correctly
    for i in 0 ..< 64:
      check almostEqual(testee1In1[i], i.float32 * 0.01, 6)
      check almostEqual(testee1In2[i], 1 - i.float32 * 0.01, 6)

    # Verify the output data was written (by checking the output port buffers)
    let out1Data = jacket.getMockPortData(cast[jacket.Port](1))  # out1Port is likely port ID 1
    let out2Data = jacket.getMockPortData(cast[jacket.Port](2))  # out2Port is likely port ID 2
    
    for i in 0 ..< 64:
      check almostEqual(out1Data[i], i.float32 * 0.001, 6)
      check almostEqual(out2Data[i], 1 - i.float32 * 0.001, 6)

  test "midi sending and receiving":
    var receivedEvents: seq[tuple[time: NFrames, data: seq[byte]]] = @[]
    
    # Test that withJack can create MIDI ports and handle MIDI events
    withJack midiOut=(mo), midiIn=(mi), mainApp=false:
      # Read incoming MIDI events
      for event in mi.read():
        var eventData = newSeq[byte](event.size)
        for i in 0..<event.size:
          eventData[i] = event.buffer[i]
        receivedEvents.add((time: event.time, data: eventData))
      
      # Send MIDI note on message (Note C4, velocity 64)
      let noteOnMsg = [0x90.byte, 60, 64]  # MIDI note on, channel 0, note 60, velocity 64
      mo.send(32, noteOnMsg)
      
      # Send MIDI note off message (Note C4)  
      let noteOffMsg = [0x80.byte, 60, 0]  # MIDI note off, channel 0, note 60, velocity 0
      mo.send(48, noteOffMsg)
    
    # Set up input MIDI data for the process callback to receive
    let miPort = cast[jacket.Port](2)  # mi port is likely port ID 2
    jacket.setMockMidiEvent(miPort, 16, [0x91.byte, 67, 127])  # Note on G4, velocity 127
    jacket.setMockMidiEvent(miPort, 32, [0x81.byte, 67, 0])    # Note off G4
    
    # Trigger the process callback
    discard jacket.simulateProcessCycle(64)
    
    # Verify we received the input MIDI events
    check receivedEvents.len == 2
    check receivedEvents[0].time == 16
    check receivedEvents[0].data == @[0x91.byte, 67, 127]
    check receivedEvents[1].time == 32  
    check receivedEvents[1].data == @[0x81.byte, 67, 0]
    
    # Verify we sent the output MIDI events
    let moPort = cast[jacket.Port](1)  # mo port is likely port ID 1
    let sentEvents = jacket.getMockMidiEvents(moPort)
    check sentEvents.len == 2
    check sentEvents[0].time == 32
    check sentEvents[0].data == @[0x90.byte, 60, 64]
    check sentEvents[1].time == 48
    check sentEvents[1].data == @[0x80.byte, 60, 0]
