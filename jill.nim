import std/[strutils,macros,os,logging]
import jill/os
import jacket

type JackBufferP = ptr UncheckedArray[DefaultAudioSample]

template defaultClientName*(): string =
  getAppFilename().lastPathPart.changeFileExt("")

# internal helpers for the withjack macro

template parsePorts(portDefinition: untyped, portType: string): seq[string] =
  #echo portDefinition.kind
  case portDefinition.kind
  of nnkIdent:
    @[portDefinition.repr]
  of nnkTupleConstr, nnkPar:
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

macro withJack*(args: varargs[untyped]): untyped =

  # this is the pre processing stage to just get an array of strings
  # describing the inputs and outputs from the fancy Nim syntax

  # Parse varargs to extract parameters with defaults, supporting both positional and named args
  var
    audioIn, audioOut, clientName, client, mainApp, body: NimNode
  
  for i, arg in args:

    case arg.kind:
    of nnkPar:
      # positional
      case i:
      of 0:
        audioOut = arg
      of 1:
        audioIn = arg
      of 4:
        clientName = arg
      of 5:
        client = arg
      of 6:
        mainApp = arg
      else:
        error("Too many positional arguments")
    of nnkExprEqExpr:
      # Named argument: name: value
      let name = arg[0]
      let value = arg[1]
      case $name:
      of "audioOut":
        if not audioOut.isNil:
          error("output parameter set both positionally and as named argument")
        audioOut = value
      of "audioIn":
        if not audioIn.isNil:
          error("audioIn parameter set both positionally and as named argument")
        audioIn = value
      of "client":
        if not clientName.isNil:
          error("clientName parameter set both positionally and as named argument")
        clientName = value
      of "clientName":
        if not clientName.isNil:
          error("clientName parameter set both positionally and as named argument")
        clientName = value
      of "mainApp":
        if not mainApp.isNil:
          error("mainApp parameter set both positionally and as named argument")
        mainApp = value
      else:
        error("Unknown parameter: " & $name)
    of nnkStmtList:
      if i == args.len-1:
        body = arg
      else:
        error("withJack body should come at the end")
    else:
      error("Unexpected withJack parameter: " & $arg.repr)

  if audioOut.isNil and audioIn.isNil:
    error("Need at least one output or input")
  
  # in order to refer to the same identifier in different code snippets
  # it needs to be generated here and injected everywhere it is needed
  # otherwise 'foo' is not the same as 'foo' in different AST snippets
  # set these early so they are available
  let
    identStatus = ident("status")
    identClient = ident("client")
    identNframes = ident("nframes")
    identProc = ident("processImpl")
    identVarProc = ident("processImplVar")
    identArg = ident("arg")

  # Now set the default values
  # they might need the ident vars above

  if audioIn.isNil:
    audioIn = quote: ()
  if audioOut.isNil:
    audioOut = quote: ()
  if clientName.isNil:
    clientName = quote: defaultClientName()
  if client.isNil:
    client = quote: clientOpen(`clientName`, NullOption, `identStatus`.addr)
  if mainApp.isNil:
    mainApp = newLit(false)
  if body.isNil:
    error("withJack requires a body block")

  let
    audioOutNames = parsePorts(audioOut, "output")
    audioInNames = parsePorts(audioIn, "input")

  # Now we will loop over the input and output names in order to generate four
  # different code snippets to do the work of having a jack client.
  # 
  # - register a port
  # - get that port's buffer as a pointer (expectation to write only to outputs)
  # - define a Nim procedure with openArray[float32] parameters for inputs and var
  #   openArray[float32] for outputs
  # - A call to that procedure passing the correct input and output buffers
  #   this happens inside the jack process callback


  var
    # the four Nim AST snippets we will make looping over the port names
    # register ports and define buffers are pretty clear
    registerPorts = newStmtList()
    defineBuffers = newStmtList()
    
    # for procedure parameters we have two snippets, one for input and one for output
    audioInDef = nnkIdentDefs.newTree()
    audioOutDef= nnkIdentDefs.newTree()

    # a snippet to dynamically cast the procedure from a pointer
    # (required to support the closure calling convention)
    processProcCast = nnkVarSection.newTree

    # and a snippets for the procedure call
    processProcCall = nnkCall.newTree()
  
  processProcCall.add(identVarProc)

  for portType, portNames in @[
    ("input", audioInNames),
    ("output", audioOutNames)
  ].items():
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
        audioInDef.add ident(portName)
      else:
        audioOutDef.add ident(portName)
 
      # now add to the outputs for the procedure call with appropriate length
      var paramCall = nnkCall.newTree
      paramCall.add ident("toOpenArray")
      paramCall.add ident(portName)
      paramCall.add newIntLitNode(0)
      var infix = nnkInfix.newTree
      infix.add ident("-")
      var intified = nnkCall.newTree
      intified.add ident("int")
      intified.add identNframes
      infix.add intified
      infix.add newIntLitNode(1)
      paramCall.add infix

      processProcCall.add paramCall

  # add openArray[float32] type to input parameters
  audioInDef.add nnkBracketExpr.newTree(ident("openArray"), ident("float32"))
  audioInDef.add newEmptyNode()

  # add var openArray[float32] type to output parameters
  audioOutDef.add nnkVarTy.newTree nnkBracketExpr.newTree(ident("openArray"), ident("float32"))
  audioOutDef.add newEmptyNode()

  # add inputs and outputs to parameters
  var params = nnkFormalParams.newTree(newEmptyNode())
  if audioInNames.len > 0:
    params.add(audioInDef)
  if audioOutNames.len > 0:
    params.add(audioOutDef)
  
  # this results in the following procedure definition
  # proc processImpl(input1, input2, ...: openArray[float32], outpu1, output2, ...: var openArray[float32])
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
    var audioInDef = nnkIdentDefs.newTree
    var bracket = nnkBracketExpr.newTree
    var castdef = nnkCast.newTree
    var ptrdef = nnkPtrTy.newTree
    var procdef = nnkProcTy.newTree
   
    # copy the entire param definition input1: openArray[float32]...
    # for the procedure type cast
    # var processImpl = cast[ptr proc(...)](
    procdef.add params.copyNimTree
    procdef.add newEmptyNode()
    ptrdef.add procdef
    castdef.add ptrdef
    castdef.add identArg
    bracket.add castdef
    audioInDef.add identVarProc
    audioInDef.add newEmptyNode()
    audioInDef.add bracket
    processProcCast.add audioInDef

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
        `identStatus`: cint
        `identClient` {.inject.} = `client`
        rate {.inject.}: NFrames
        frames {.inject.}: NFrames

      if `identClient`.isNil:
        debug "jack client open failed, status: $1" % $`identStatus`
        when `mainApp`:
          quit 1
      debug "client $# connected" % clientName

      proc cleanup() {.cdecl.} =
        debug "cleanup"
        if `identClient` != nil:
          `identClient`.deactivate()
          `identClient`.clientClose()
          `identClient` = nil

      when `mainApp`:
        proc signal(sig: cint) {.noconv.} =
          debug "received signal: $#" % $sig
          cleanup()
          quit 0

      proc shutdown(arg: pointer = nil) {.cdecl.} =
        debug "jack server shutdown"
        cleanup()
        when `mainApp`:
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

      proc changeSampleRate(nframes: NFrames, arg: pointer): cint {.cdecl.} =
        var sampleRatePtr = cast[ptr NFrames](arg)
        sampleRatePtr[] = nframes
        debug "sample rate $#" % $nframes
      
      proc changeBufferSize(nframes: NFrames, arg: pointer): cint {.cdecl.} =
        var bufferSizePtr = cast[ptr NFrames](arg)
        bufferSizePtr[] = nframes
        debug "buffer size $#" % $nframes

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

      `identClient`.onShutdown(shutdown)
      var processImplVar = processImpl
      if 0 != `identClient`.setProcessCallback(process, processImplVar.addr):
        debug "could not set process callback"
      if 0 != `identClient`.setClientRegistrationCallback(registerClient):
        debug "could not set client registration callback"
      if 0 != `identClient`.setPortRegistrationCallback(registerPort):
        debug "could not set port registration callback"
      if 0 != `identClient`.setXrunCallback(xrun):
        debug "could not set xrun callback"
      if 0 != `identClient`.setPortRenameCallback(renamePort):
        debug "could not set port rename callback"
      if 0 != `identClient`.setSampleRateCallback(changeSampleRate, rate.addr):
        debug "could not set sample rate callback"
      if 0 != `identClient`.setSampleRateCallback(changeBufferSize, frames.addr):
        debug "could not set buffer size callback"
      if 0 != `identClient`.setPortConnectCallback(connectPort):
        debug "could not set port connect callback"
      
      when `mainApp`:
        when defined(windows):
          setSignalProc(signal, SIGABRT, SIGINT, SIGTERM)
        else:
          setSignalProc(signal, SIGABRT, SIGHUP, SIGINT, SIGQUIT, SIGTERM)

      if 0 != `identClient`.activate:
        debug "could not activate"
        when `mainApp`:
          quit 1

      when `mainApp`:
        while true:
          sleep(high(int))

        cleanup()

  # echo result.repr  


