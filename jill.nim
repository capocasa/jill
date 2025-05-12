import std/[strutils,macros,os,logging]
import jill/signal
import jacket

type JackBufferP = ptr UncheckedArray[DefaultAudioSample]

macro withJack*(input: untyped, output: untyped, processBlock: untyped): untyped =
  echo input.treeRepr
  echo output.treeRepr
  quote do:

    block:
      const size = sizeof(DefaultAudioSample)
      var
        inputPort, outputPort: Port
        n = 64
        log = newConsoleLogger(when defined(release): lvlInfo else: lvlDebug)
        clientName = "comus"
        serverName = "" 
        status: cint
        client: Client
      
      proc cleanup() =
        debug "Cleaning up..."
        if client != nil:
          client.deactivate()
          client.clientClose()
          client = nil

      proc signal(sig: cint) {.noconv.} =
          debug "Received signal: " & $sig
          cleanup()
          quit 0

      proc shutdown(arg: pointer = nil) {.cdecl.} =
          warn "JACK server has shut down."
          cleanup()
          quit 0

      proc connectPort(portIdA: PortId; portIdB: PortId; connect: cint; arg: pointer) {.cdecl.} =
        let portA = client.portById(portIdA)
        let portB = client.portById(portIdB)
        debug if connect > 0: "connect" else: "disconnect", " port ", portA.portName, " to ", portB.portName

      proc registerPort(portId: PortId, flag: cint, arg: pointer) {.cdecl.} =
        let port = client.portById(portId)
        debug "register port ", port.portName

      proc registerClient(name: cstring, flag: cint; arg: pointer) {.cdecl.} =
        debug "register client ", name

      proc xrun(arg: pointer): cint {.cdecl.} =
        debug "xrun"
      
      proc renamePort(portId: PortId, oldName, newName: cstring, arg: pointer) {.cdecl.} =
        debug "rename port ", oldName, " to ", " ", newName

      proc sampleRate(nframes: NFrames, arg: pointer): cint {.cdecl.} =
        debug "sample rate ", nframes

      proc timebase(state: TransportState, nframes: NFrames, post: ptr Position, newPost: cint, arg: pointer) {.cdecl.} =
        debug "timebase"

      proc process(nframes: NFrames, arg: pointer): cint {.cdecl.} =
        # TODO: nim exceptions don't work in the process block
        let inBuf {.inject.} = cast[JackBufferP](portGetBuffer(inputPort, nframes))
        let outBuf {.inject.} = cast[JackBufferP](portGetBuffer(outputPort, nframes))
        `processBlock`
        return 0

      when defined(windows):
        setSignalProc(signal, SIGABRT, SIGINT, SIGTERM)
      else:
        setSignalProc(signal, SIGABRT, SIGHUP, SIGINT, SIGQUIT, SIGTERM)

      client = clientOpen(clientName, NullOption, status.addr, serverName)
      if client.isNil:
        stderr.write "jack connect failed, status: $1\n" % $status
        quit 1

      client.onShutdown(shutdown)
      if 0 != client.setProcessCallback(process, nil):
        debug "could not set process callback"
      if 0 != client.setClientRegistrationCallback(registerClient):
        debug "could not set client registration callback"
      if 0 != client.setPortRegistrationCallback(registerPort):
        debug "could not set port registration callback"
      if 0 != client.setXrunCallback(xrun):
        debug "could not set xrun callback"
      if 0 != client.setPortRenameCallback(renamePort):
        debug "could not set port rename callback"
      if 0 != client.setSampleRateCallback(sampleRate):
        debug "could not set sample rate callback"
      if 0 != client.setPortConnectCallback(connectPort):
        debug "could not set port connect callback"

      inputPort = client.portRegister("input", JackDefaultAudioType, PortIsInput, 0)
      if inputPort.isNil:
        stderr.write "could not connect input port\n"
        quit 1

      outputPort = client.portRegister("output", JackDefaultAudioType, PortIsOutput, 0)
      if outputPort.isNil:
        stderr.write "could not connect output port\n"
        quit 1


      if 0 != client.activate:
        stderr.write "Cannot activate\n"
        quit 1

      block:
        let ports = client.getPorts(nil, nil, PortIsPhysical or PortIsOutput)
        if ports.isNil:
          debug "no input ports\n"
          break
        if 0 != client.connect(ports[0], inputPort.portName):
          debug "cannot connect input ports\n"
        free(ports)

      block:
        let ports = client.getPorts(nil, nil, PortIsPhysical or PortIsInput)
        if ports.isNil:
          debug "no output ports\n"
          break
        if 0 != client.connect(outputPort.portName, ports[0]):
          debug "cannot connect input ports\n"
        free(ports)


      while true:
        sleep(high(int))

      cleanup()

