import std/[strutils,macros,os,logging]
import jill/signal
import jacket

type JackBufferP = ptr UncheckedArray[DefaultAudioSample]

let defaultClientName = getAppFilename().lastPathPart.changeFileExt("")

macro withJack*(input, output: untyped, clientName: string, body: untyped): untyped =

  template parsePorts(portDefinition: untyped, portType: string): seq[string] =
    case portDefinition.kind
    of nnkIdent:
      @[portDefinition.repr]
    of nnkTupleConstr:
      var portNames:seq[string]
      for i,n in portDefinition:
        case n.kind
        of nnkExprColonExpr:
          error(portType & "s my not contain a colon")
        else:
          portNames.add n.repr
      portNames
    else:
      error(portType & " must be identifier or tuple representing names to be given to inputs")
  
  # Generate code blocks that contain input and output buffers from jack

  let
    identClient = ident("client")
    identNframes = ident("nframes")

  var
    registerPorts = newStmtList()
    defineBuffers = newStmtList()
  for portType, portParam in {"input": input, "output": output}.items():
    for portName in parsePorts(portParam, portType):
      # register port and define buffer in process callback for each input or output
 
      let
        identBuffer = ident(portName)
        identPort = ident(portName & "Port")
        identPortTypeFlag = if portType=="input": PortIsInput else: PortIsOutput
 
      registerPorts.add quote do:
        let `identPort` = `identClient`.portRegister(`portName`, JackDefaultAudioType, `identPortTypeFlag`, 0)
        if `identPort`.isNil:
          debug "could not register port '$#'" % `portName`
          quit 1

      defineBuffers.add quote do:
        let `identBuffer` {.inject.} = cast[JackBufferP](portGetBuffer(`identPort`, `identNframes`))

  #main macro body, this is jill's main jack client implementation. Most is static code in quote do

  quote do:
    block:
      const size = sizeof(DefaultAudioSample)
      var
        clientName = `clientName`
        status: cint
        `identClient` = clientOpen(clientName, NullOption, status.addr)

      if `identClient`.isNil:
        debug "jack client open failed, status: $1" % $status
        quit 1
      debug "client $# connected" % clientName

      proc cleanup() {.cdecl.} =
        debug "cleanup"
        if `identClient` != nil:
          `identClient`.deactivate()
          `identClient`.clientClose()
          `identClient` = nil

      proc signal(sig: cint) {.noconv.} =
        debug "received signal: $#" % $sig
        cleanup()
        quit 0

      proc shutdown(arg: pointer = nil) {.cdecl.} =
        warn "jack server shutdown"
        cleanup()
        quit 0

      proc connectPort(portIdA: PortId; portIdB: PortId; connect: cint; arg: pointer) {.cdecl.} =
        let portA = `identClient`.portById(portIdA)
        let portB = `identClient`.portById(portIdB)
        debug "$# port $# to $#" % [if connect > 0: "connect" else: "disconnect", $portA.portName, $portB.portName]

      proc registerPort(portId: PortId, flag: cint, arg: pointer) {.cdecl.} =
        let port = `identClient`.portById(portId)
        debug "register port $#" % $port.portName

      proc registerClient(name: cstring, flag: cint; arg: pointer) {.cdecl.} =
        debug "register client $#" % $name

      proc xrun(arg: pointer): cint {.cdecl.} =
        debug "xrun"
      
      proc renamePort(portId: PortId, oldName, newName: cstring, arg: pointer) {.cdecl.} =
        debug "rename port $# to $#" % [$oldName, $newName]

      proc sampleRate(nframes: NFrames, arg: pointer): cint {.cdecl.} =
        debug "sample rate $#" % $nframes

      proc timebase(state: TransportState, nframes: NFrames, post: ptr Position, newPost: cint, arg: pointer) {.cdecl.} =
        debug "timebase"

      `registerPorts`
      
      proc doProcess(`identNframes`: NFrames) =
        `defineBuffers`
        `body`

      proc process(nframes: NFrames, arg: pointer): cint {.cdecl.} =
        # TODO: nim exceptions don't work in the process block
        var doProcessVar = cast[ptr proc (nframes: NFrames)](arg)
        doProcessVar[](nframes)
        return 0

      when defined(windows):
        setSignalProc(signal, SIGABRT, SIGINT, SIGTERM)
      else:
        setSignalProc(signal, SIGABRT, SIGHUP, SIGINT, SIGQUIT, SIGTERM)

      `identClient`.onShutdown(shutdown)
      var doProcessVar = doProcess
      if 0 != `identClient`.setProcessCallback(process, doProcessVar.addr):
        debug "could not set process callback"
      if 0 != `identClient`.setClientRegistrationCallback(registerClient):
        debug "could not set client registration callback"
      if 0 != `identClient`.setPortRegistrationCallback(registerPort):
        debug "could not set port registration callback"
      if 0 != `identClient`.setXrunCallback(xrun):
        debug "could not set xrun callback"
      if 0 != `identClient`.setPortRenameCallback(renamePort):
        debug "could not set port rename callback"
      if 0 != `identClient`.setSampleRateCallback(sampleRate):
        debug "could not set sample rate callback"
      if 0 != `identClient`.setPortConnectCallback(connectPort):
        debug "could not set port connect callback"

      if 0 != `identClient`.activate:
        debug "could not activate"
        quit 1

      #[
      block:
        let ports = `identClient`.getPorts(nil, nil, PortIsPhysical or PortIsOutput)
        if ports.isNil:
          debug "no input ports"
          break
        if 0 != `identClient`.connect(ports[0], inputPort.portName):
          debug "could not connect input ports"
        free(ports)

      block:
        let ports = `identClient`.getPorts(nil, nil, PortIsPhysical or PortIsInput)
        if ports.isNil:
          debug "no output ports"
          break
        if 0 != `identClient`.connect(outputPort.portName, ports[0]):
          debug "could not connect input ports"
        free(ports)
      ]#

      while true:
        sleep(high(int))

      cleanup()


