packageName   = "weave_io"
version       = "0.3.0"
author        = "Mamy Ratsimbazafy"
description   = "A latency and fairness optimized threadpool for IO with decent compute performance."
license       = "MIT or Apache License 2.0"

# Dependencies
# ----------------------------------------------------------------

requires "nim >= 2.0.2"
  # We don't want to deal with nim 1.x, refc GC and ref/async

# Nimscript imports
# ----------------------------------------------------------------

import std/[strformat, strutils, os]

# Test config
# ----------------------------------------------------------------

func compilerFlags(): string =
  " -d:release " &
  " --verbosity:0 --hints:off --warnings:off " &
  " --threads:on --tlsEmulation=off "

# Skip stack hardening for specific tests
const skipStackHardening = [
  "tests/t_"
]
# use sanitizers for specific tests
const useSanitizers = [
  "tests/t_",
]

const testDescThreadpool: seq[string] = @[
  "examples/e01_simple_tasks.nim",
  "examples/e02_parallel_pi.nim",
  "examples/e03_parallel_for.nim",
  "examples/e04_parallel_reduce.nim",
  # "benchmarks/bouncing_producer_consumer/threadpool_bpc.nim", # Need timing not implemented on Windows
  "benchmarks/dfs/threadpool_dfs.nim",
  "benchmarks/fibonacci/threadpool_fib.nim",
  "benchmarks/heat/threadpool_heat.nim",
  # "benchmarks/matmul_cache_oblivious/threadpool_matmul_co.nim",
  "benchmarks/nqueens/threadpool_nqueens.nim",
  # "benchmarks/single_task_producer/threadpool_spc.nim", # Need timing not implemented on Windows
  # "benchmarks/black_scholes/threadpool_black_scholes.nim", # Need input file
  "benchmarks/matrix_transposition/threadpool_transposes.nim",
  "benchmarks/histogram_2D/threadpool_histogram.nim",
  "benchmarks/logsumexp/threadpool_logsumexp.nim",
]

when defined(windows):
  # UBSAN is not available on mingw
  # https://github.com/libressl-portable/portable/issues/54
  const sanitizers = ""
  const stackHardening = ""
else:
  const stackHardening =
    " --passC:-fstack-protector-strong " &
    " --passC:-D_FORTIFY_SOURCE=3 "

  const sanitizers =

    # Sanitizers are incompatible with nim default GC
    # The conservative stack scanning of Nim default GC triggers, alignment UB and stack-buffer-overflow check.
    # Address sanitizer requires free registers and needs to be disabled for some inline assembly files.
    # Ensure you use --mm:arc -d:useMalloc
    #
    # Sanitizers are deactivated by default as they slow down CI by at least 6x

    " --mm:arc -d:useMalloc" &
    " --passC:-fsanitize=undefined --passL:-fsanitize=undefined" &
    " --passC:-fsanitize=address --passL:-fsanitize=address" &
    " --passC:-fno-sanitize-recover" # Enforce crash on undefined behaviour

# Test procedures
# ----------------------------------------------------------------

proc setupTestCommand(flags, path: string): string =
  var lang = "c"
  if existsEnv"TEST_LANG":
    lang = getEnv"TEST_LANG"

  return "nim " & lang &
    " -r " &
    flags &
    compilerFlags() &
    " --outdir:build/test_suite " &
    &" --nimcache:nimcache/{path} " &
    path

proc testBatch(commands: var string, flags, path: string) =
  commands = commands & setupTestCommand(flags, path) & '\n'

proc addTestSetThreadpool(cmdFile: var string) =
  if not dirExists "build":
    mkDir "build"
  echo "Found " & $testDescThreadpool.len & " tests to run."

  for path in testDescThreadpool:
    var flags = " --debugger:native "
    if path notin skipStackHardening:
      flags = flags & stackHardening
    if path in useSanitizers:
      flags = flags & sanitizers
    cmdFile.testBatch(flags, path)

task test, "Run all tests":
  var cmdFile: string
  cmdFile.addTestSetThreadpool()
  for cmd in cmdFile.splitLines():
    if cmd != "": # Windows doesn't like empty commands
      exec cmd
