import std/[strutils,macros,os,logging]
import jill/signal
import jacket

type JackBufferP = ptr UncheckedArray[DefaultAudioSample]

macro withJack*(input, output, clientName, body: untyped): untyped =
  
  # this is the pre processing stage to just get an array of strings
  # describing the inputs and outputs from the fancy Nim syntax

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

  let
    inputNames = parsePorts(input, "input")
    outputNames = parsePorts(output, "output")

  # Now we will loop over the input and output names in order to generate four
  # different code snippets to do the work of having a jack client.
  # 
  # - register a port
  # - get that port's buffer as a pointer (expectation to write only to outputs)
  # - define a Nim procedure with openArray[float] parameters for inputs and var
  #   openArray[float] for outputs
  # - A call to that procedure passing the correct input and output buffers
  #   this happens inside the jack process callback

  let
    # in order to refer to the same identifier in different code snippets
    # it needs to be generated here and injected everywhere it is needed
    # otherwise 'foo' is not the same as 'foo' in different AST snippets
    identClient = ident("client")
    identNframes = ident("nframes")
    identProc = ident("processImpl")
    identVarProc = ident("processImplVar")
    identArg = ident("arg")

  var
    # the four Nim AST snippets we will make looping over the port names
    # register ports and define buffers are pretty clear
    registerPorts = newStmtList()
    defineBuffers = newStmtList()
    
    # for procedure parameters we have two snippets, one for input and one for output
    indef = nnkIdentDefs.newTree()
    outdef = nnkIdentDefs.newTree()

    # a snippet to dynamically cast the procedure from a pointer
    # (required to support the closure calling convention)
    processProcCast = nnkVarSection.newTree

    # and a snippets for the procedure call
    processProcCall = nnkCall.newTree()
  
  processProcCall.add(identVarProc)

  for portType, portNames in {"input": inputNames, "output": outputNames}.items():
    for portName in portNames:

      # register port and define buffer in process callback for each input or output
      let
        identBuffer = ident(portName)
        identPort = ident(portName & "Port")
        identPortTypeFlag = if portType=="input": PortIsInput else: PortIsOutput

      # make sure a jack port gets registered for input or output
      registerPorts.add quote do:
        let `identPort` = `identClient`.portRegister(`portName`, JackDefaultAudioType, `identPortTypeFlag`, 0)
        if `identPort`.isNil:
          debug "could not register port '$#'" % `portName`
          quit 1

      # have a buffer defined in the process proc
      defineBuffers.add quote do:
        let `identBuffer` = cast[JackBufferP](portGetBuffer(`identPort`, `identNframes`))
  
      # have an openArray parameter in the processInput proc, writable only
      # for outputs, for Nimish but zero-copy input and output

      if portType == "input":
        indef.add ident(portName)
      else:
        outdef.add ident(portName)
 
      # now add to the outputs for the procedure call with appropriate length
      var paramCall = nnkCall.newTree
      paramCall.add ident("toOpenArray")
      paramCall.add ident(portName)
      paramCall.add newIntLitNode(0)
      var infix = nnkInfix.newTree
      infix.add ident("-")
      infix.add ident("n")
      infix.add newIntLitNode(1)
      paramCall.add infix

      processProcCall.add paramCall

  # add openArray[float] type to input parameters
  indef.add nnkBracketExpr.newTree(ident("openArray"), ident("float"))
  indef.add newEmptyNode()

  # add var openArray[float] type to output parameters
  outdef.add nnkVarTy.newTree nnkBracketExpr.newTree(ident("openArray"), ident("float"))
  outdef.add newEmptyNode()

  # add inputs and outputs to parameters
  var params = nnkFormalParams.newTree(newEmptyNode())
  if inputNames.len > 0:
    params.add(indef)
  if outputNames.len > 0:
    params.add(outdef)
  
  # this results in the following procedure definition
  # proc processImpl(input1, input2, ...: openArray[float], outpu1, output2, ...: var openArray[float])
  var processProcDef = nnkProcDef.newTree
  processProcDef.add identProc
  processProcDef.add newEmptyNode()
  processProcDef.add newEmptyNode()
  processProcDef.add params
  processProcDef.add newEmptyNode()
  processProcDef.add newEmptyNode()
  processProcDef.add body

  # procedure call first needs a variable definition and cast, because it's sent
  # through to the cdecl jack callback with the arg pointer
  # to make the process function support closure

  block:  # shorter var names in own scope
    var indef = nnkIdentDefs.newTree
    var bracket = nnkBracketExpr.newTree
    var castdef = nnkCast.newTree
    var ptrdef = nnkPtrTy.newTree
    var procdef = nnkProcTy.newTree
   
    # copy the entire param definition input1: openArray[float]...
    # for the procedure type cast
    # var processImpl = cast[ptr proc(...)](
    procdef.add params.copyNimTree
    procdef.add newEmptyNode()
    ptrdef.add procdef
    castdef.add ptrdef
    castdef.add identArg
    bracket.add castdef
    indef.add identVarProc
    indef.add newEmptyNode()
    indef.add bracket
    processProcCast.add indef

  # Now comes the main macro body, which is the bulk of the jack
  # implementation as a big quote do block. Static code changes
  # are usually straight forward here, just like regular Nim code.
  # The snippets generated above are inserted here in backquotes ``
  # as normal for a quote do.

  result = quote do:
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

      `processProcDef`

      proc process(`identNframes`: NFrames, `identArg`: pointer): cint {.cdecl.} =
        # TODO: nim exceptions don't work in the process block
        `processProcCast`
        `defineBuffers`
        `processProcCall`
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

  echo result.repr  

template defaultClientName*(): string =
  getAppFilename().lastPathPart.changeFileExt("")

template withJack*(output, clientName, body: untyped): untyped =
  withJack((), output, clientName, body)

template withJack*(output, body: untyped): untyped =
  withJack((), output, defaultClientName(), body)

