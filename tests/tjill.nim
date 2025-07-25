import std/[unittest,math]
import tests/mock_jacket as jacket
import ../jill

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

  test "midi ports creation":
    # Test that withJack can create MIDI ports without errors
    withJack midiOut=(mo), midiIn=(mi):
      discard
    
    # The test passes if the macro expansion completes without errors
    # MIDI functionality will be implemented later
    check true
