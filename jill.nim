import macros

macro withJack*(in, out: untyped = ""): untyped =
  echo in.treeRepr
  echo out.treeRepr

