import std/[strutils,macros,os]
import jackfu
from system/ansi_c import c_free

macro withJack*(input: untyped, output: untyped, processBlock: untyped): untyped =
  echo input.treeRepr
  echo output.treeRepr
  quote do:
    block:
      var inputPort, outputPort: Port

      const size = sizeof(Sample)
      const n = 64

      # TODO: nim exceptions don't work in the process block
      proc process(nframes: jackNframesT, arg: pointer): cint {.cdecl.} =
        let inBuf {.inject.} = cast[ptr UncheckedArray[Sample]](jackPortGetBuffer(inputPort, nframes))
        let outBuf {.inject.} = cast[ptr UncheckedArray[Sample]](jackPortGetBuffer(outputPort, nframes))
        `processBlock`
        return 0

      var clientName = "comus"
      let serverName = "" 
      var status:enumJackStatus
      let options = JackNullOption

      let client = jackClientOpen(clientName, options, status.addr, serverName)
      if client.isNil:
        stderr.write "jack connect failed, status: $1\n" % $status
        quit 1

      discard jackSetProcessCallback(client, process, nil)

      proc shutdown(arg: pointer) {.cdecl.} =
        stderr.write "Shutdown called\n"
        quit 1
      jackOnShutdown(client, shutdown, nil)

      inputPort = jackPortRegister(client, "input", JACK_DEFAULT_AUDIO_TYPE, JackPortIsInput.uint, 0)
      if inputPort.isNil:
        stderr.write "could not connect input port\n"
        quit 1

      outputPort = jackPortRegister(client, "output", JACK_DEFAULT_AUDIO_TYPE, JackPortIsOutput.uint, 0)
      if outputPort.isNil:
        stderr.write "could not connect output port\n"
        quit 1

      if 0 != jackActivate(client):
        stderr.write "Cannot activate\n"
        quit 1

      block:
        let ports = jackGetPorts(client, nil, nil, JackPortIsPhysical.uint or JackPortIsOutput.uint)
        if ports.isNil:
          stderr.write "no input ports\n"
          break
        if 0 != jackConnect(client, ports[], jackPortName(inputPort)):
          stderr.write "cannot connect input ports\n"
        cFree(ports)

      block:
        let ports = jackGetPorts(client, nil, nil, JackPortIsPhysical.uint or JackPortIsInput.uint)
        if ports.isNil:
          stderr.write "no output ports\n"
          break
        if (0 != jackConnect(client, jackPortName(outputPort), ports[])):
          stderr.write "cannot connect output ports\n"
        cFree(ports)

      while true:
        sleep(high(int))

      discard jackClientClose(client)

