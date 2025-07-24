import std/[unittest,osproc,os,streams,exitprocs,math]
import ../jill
import jacket

suite "Jill":

  # start a dummy jack server and be really sure it will quit when the test program exits
  let p = startProcess("jackd", "", @["--name", "jillTestServer", "-d", "dummy", "-r", "48000", "-p", "64"], nil, {poUsePath, poDaemon, poStdErrToStdOut})
  defer:
    p.kill
  proc cleanup() {.noconv.} =
    p.kill
  addExitProc cleanup
  setControlCHook cleanup
  block waitAlittle:
    for i in 0..20:
      sleep 100
      if p.running:
        break waitAlittle
    assert false, "server didn't start, giving up"

  # use low-level jacket API to set up a test client that is independent
  # of the jill code and is known to work.
  putEnv("JACK_DEFAULT_SERVER", "jillTestServer")

  var
    testerIn1, testerIn2: array[64, float32]  # global scope vars for assertions
 
  let
    testClient = clientOpen("tester", NullOption, nil)

    portIn1 = testClient.portRegister("in1", JackDefaultAudioType, PortIsInput, 0)
    portIn2  = testClient.portRegister("in2", JackDefaultAudioType, PortIsInput, 0)
    portOut1 = testClient.portRegister("out1", JackDefaultAudioType, PortIsOutput, 0)
    portOut2 = testClient.portRegister("out2", JackDefaultAudioType, PortIsOutput, 0)

  proc testCallback(nframes: Nframes, arg: pointer): cint {.cdecl.} =
    var
      in1 = cast[ptr array[64, float32]](portGetBuffer(portIn1, nframes))
      in2 = cast[ptr array[64, float32]](portGetBuffer(portIn2, nframes))
      out1 = cast[ptr array[64, float32]](portGetBuffer(portOut1, nframes))
      out2 = cast[ptr array[64, float32]](portGetBuffer(portOut2, nframes))
    for i in 0..<nframes:
      # just copy data from input into global vars so we can do checks
      testerIn1[i] = in1[i]
      testerIn2[i] = in2[i]

      # output a test signal to do checks
      out1[i] = i.float * 0.01
      out2[i] = 1.0 - out1[i]
    return 0
  assert testClient.setProcessCallback(testCallback, nil) == 0

  setup:
    assert testClient.activate() == 0

  teardown:
    assert testClient.deactivate() == 0
    discard

  test "one cycle of stereo input and output":
    var
      testeeIn1, testeeIn2: array[64, float32]
    withJack audioOut=(out1, out2), audioIn=(in1, in2), mainApp=false, clientName="testee":
      for i in 0..in1.len-1:
        testeeIn1[i] = in1[i]
        testeeIn2[i] = in2[i]

        # a different test signal
        out1[i] = i.float32 * 0.001
        out2[i] = 1 - i.float32 * 0.001

    testClient.connect("tester:out1", "testee:in1")
    testClient.connect("tester:out2", "testee:in2")
    testClient.connect("testee:out1", "tester:in1")
    testClient.connect("testee:out2", "tester:in2")
    sleep 10  # let it run a few times it's the same data every cycle anyway
    
    for i in 0 ..< 64:
      check almostEqual(testeeIn1[i], i.float32 * 0.01, 6)
      check almostEqual(testeeIn2[i], 1 - i.float32 * 0.01, 6)
      check almostEqual(testerIn1[i], i.float32 * 0.001, 6)
      check almostEqual(testerIn2[i], 1 - i.float32 * 0.001, 6)
    
    testClient.disconnect("tester:out1", "testee:in1")
    testClient.disconnect("tester:out2", "testee:in2")
    testClient.disconnect("testee:out1", "tester:in1")
    testClient.disconnect("testee:out2", "tester:in2")



