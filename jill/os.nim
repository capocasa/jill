import system/ansi_c, posix


export SIG_DFL, ansi_c.SIGABRT, SIGFPE, SIGILL, ansi_c.SIGINT, ansi_c.SIGSEGV

when not defined(windows):
  export SIGPIPE, ansi_c.SIGTERM
  var
    SIG_IGN* {.importc: "SIG_IGN", header: "<signal.h>".}: cint
    SIGHUP* {.importc: "SIGHUP", header: "<signal.h>".}: cint
    SIGQUIT* {.importc: "SIGQUIT", header: "<signal.h>".}: cint
else:
  const SIGTERM* = cint(15)

type CSighandlerT = proc (a: cint) {.noconv.}

proc setSignalProc* (`proc`: CSighandlerT, signals: varargs[cint]) =
  for sig in signals:
    discard c_signal(sig, `proc`)

proc blockSignals*(signals: varargs[cint]) =
  var 
    nmask: Sigset
    omask: Sigset
  discard sigemptyset(nmask)
  discard sigemptyset(omask)
  for signal in signals:
    discard sigaddset(nmask, signal)
  if pthread_sigmask(SIG_BLOCK, nmask, omask) == -1:
    raise newException(CatchableError, "Could not block signals")

template waitSignals*(signals: varargs[cint], body) =
  var
    sig: cint
    mask: Sigset
  discard sigemptyset(mask)
  for signal in signals:
    discard sigaddset(mask, signal)
  while true:
    discard sigwait(mask, sig)
    body


