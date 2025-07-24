import std/[strutils,macros,os,logging]
import jill/os
import jacket

type
  JackBufferP = ptr UncheckedArray[DefaultAudioSample]
  MidiBuffer = pointer

template defaultClientName*(): string =
  getAppFilename().lastPathPart.changeFileExt("")

# internal helpers for the withjack macro

template parsePorts(portDefinition: untyped, paramName: string): seq[string] =
  #echo portDefinition.kind
  case portDefinition.kind
  of nnkIdent:
    @[portDefinition.repr]
  of nnkTupleConstr, nnkPar:
    var portNames:seq[string]
    for i,n in portDefinition:
      case n.kind
      of nnkExprColonExpr:
        error(paramName & " may not contain a colon")
      else:
        portNames.add n.repr
    portNames
  else:
    error(paramName & " must be identifier or tuple representing names to be given to inputs")

macro withJack*(args: varargs[untyped]): untyped =

  # this is the pre processing stage to just get an array of strings
  # describing the inputs and outputs from the fancy Nim syntax

  # Parse varargs to extract parameters with defaults, supporting both positional and named args
  var
    audioOut, audioIn, midiOut, midiIn, clientName, client, mainApp, body: NimNode
  
  for i, arg in args:

    case arg.kind:
    of nnkPar:
      # positional
      case i:
      of 0:
        audioOut = arg
      of 1:
        audioIn = arg
      of 2:
        midiOut = arg
      of 3:
        midiIn = arg
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
          error($name & " already set")
        audioOut = value
      of "audioIn":
        if not audioIn.isNil:
          error($name & " already set")
        audioIn = value
      of "midiOut":
        if not midiOut.isNil:
          error($name & " already set")
        midiOut = value
      of "midiIn":
        if not midiIn.isNil:
          error($name & " already set")
        midiIn = value
      of "client":
        if not clientName.isNil:
          error($name & " already set")
        clientName = value
      of "clientName":
        if not clientName.isNil:
          error($name & " already set")
        clientName = value
      of "mainApp":
        if not mainApp.isNil:
          error($name & "already set")
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

  if audioOut.isNil and audioIn.isNil and midiin.isNil and midiOut.isNil:
    error("Need at least one output or input")
  
  # in order to refer to the same identifier in different code snippets
  # it needs to be generated here and injected everywhere it is needed
  # otherwise 'foo' is not the same as 'foo' in different AST snippets
  # set these early so they are available
  let
    identStatus = ident("status")
    identClient = ident("client")
    identNframes = ident("nframes")
    identProcessImpl = ident("processImpl")
    identProcessImplVar = ident("processImplVar")
    identArg = ident("arg")

  # Now set the default values
  # they might need the ident vars above

  if audioOut.isNil:
    audioOut = quote: ()
  if audioIn.isNil:
    audioIn = quote: ()
  if midiOut.isNil:
    midiOut = quote: ()
  if midiIn.isNil:
    midiIn = quote: ()
  if midiIn.isNil:
    midiIn = quote: ()
  if clientName.isNil:
    clientName = quote: defaultClientName()
  if client.isNil:
    client = quote: clientOpen(`clientName`, NullOption, `identStatus`.addr)
  if mainApp.isNil:
    mainApp = newLit(false)
  if body.isNil:
    error("withJack requires a body block")

  let
    audioOutNames = parsePorts(audioOut, "audioOut")
    audioInNames = parsePorts(audioIn, "audioIn")
    midiOutNames = parsePorts(midiOut, "midiOut")
    midiInNames = parsePorts(midiIn, "midiIn")

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
    audioOutDef= nnkIdentDefs.newTree()
    audioInDef = nnkIdentDefs.newTree()
    midiOutDef= nnkIdentDefs.newTree()
    midiInDef = nnkIdentDefs.newTree()

    # a snippet to dynamically cast the procedure from a pointer
    # (required to support the closure calling convention)
    processProcCast = nnkVarSection.newTree

    # and a snippets for the procedure call
    processProcCall = nnkCall.newTree()
  
  processProcCall.add(identProcessImplVar)

  for portType, portIoFlag, portNames in @[
    (JackDefaultAudioType, PortIsOutput, audioOutNames),
    (JackDefaultAudioType, PortIsInput, audioInNames),
    (JackDefaultMidiType, PortIsOutput, midiOutNames),
    (JackDefaultMidiType, PortIsInput, midiInNames)
  ].items():
    for portName in portNames:

      # register port and define buffer in process callback for each input or output
      let
        identBuffer = ident(portName)
        identPort = ident(portName & "Port")
      # make sure a jack port gets registered for input or output
      registerPorts.add quote do:
        let `identPort` = `identClient`.portRegister(`portName`, `portType`, `portIoFlag`, 0)
        if `identPort`.isNil:
          debug "could not register port '$#'" % `portName`
          quit 1

  
      var paramCall:NimNode
      case portType:
        of JackDefaultAudioType:
          # have a buffer defined in the process proc
          defineBuffers.add quote do:
            let `identBuffer` = cast[JackBufferP](portGetBuffer(`identPort`, `identNframes`))

          # have an openArray parameter in the processInput proc, writable only
          # for outputs, for Nimish but zero-copy input and output
          case portIoFlag:
          of PortIsOutput:
            audioOutDef.add ident(portName)
          of PortIsInput:
            audioInDef.add ident(portName)
          else:
            error "internal error, invalid portIoFlag"

          # now add to the outputs for the procedure call with appropriate length
          paramCall = nnkCall.newTree
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


        of JackDefaultMidiType:
          case portIoFlag:
          of PortIsOutput:
            midiOutDef.add ident(portName)
            defineBuffers.add quote do:
              var `identBuffer` = cast[MidiBuffer](portGetBuffer(`identPort`, `identNframes`))
          of PortIsInput:
            midiInDef.add ident(portName)
            defineBuffers.add quote do:
              let `identBuffer` = cast[MidiBuffer](portGetBuffer(`identPort`, `identNframes`))
          else:
            error "internal error, invalid portIoFlag"
          
          # midi only passes the identifier, no toOpenArray
          paramCall = ident(portName)

        else:
          error "internal error, invalid portType"

      processProcCall.add paramCall
 
  echo defineBuffers.repr

  # add var openArray[float32] type to audio output parameters
  audioOutDef.add nnkVarTy.newTree nnkBracketExpr.newTree(ident("openArray"), ident("float32"))
  audioOutDef.add newEmptyNode()

  # add openArray[float32] type to audio input parameters
  audioInDef.add nnkBracketExpr.newTree(ident("openArray"), ident("float32"))
  audioInDef.add newEmptyNode()

  # add var openArray[MidiEvent] type to MIDI output parameters
  midiOutDef.add nnkVarTy.newTree getType(bind(MidiBuffer))
  midiOutDef.add newEmptyNode()
  
  # add openArray[MidiEvent] type to MIDI input parameters
  midiInDef.add getType(bind(MidiBuffer))
  midiInDef.add newEmptyNode()

  # add inputs and outputs to parameters
  var params = nnkFormalParams.newTree(newEmptyNode())
  if audioOutNames.len > 0:
    params.add(audioOutDef)
  if audioInNames.len > 0:
    params.add(audioInDef)
  if midiOutNames.len > 0:
    params.add(midiOutDef)
  if midiInNames.len > 0:
    params.add(midiInDef)
  
  # this results in the following procedure definition
  # proc processImpl(output1, output2, ...: var openArray[float32], input1, input1, ...: openArray[float32])
  var processProcDef = nnkProcDef.newTree
  processProcDef.add identProcessImpl
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
   
    # copy the entire param definition input1: openArray[float32]...
    # for the procedure type cast
    # var processImpl = cast[ptr proc(...)](
    procdef.add params.copyNimTree
    procdef.add newEmptyNode()
    ptrdef.add procdef
    castdef.add ptrdef
    castdef.add identArg
    bracket.add castdef
    indef.add identProcessImplVar
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


