# Weave-IO
# Copyright (c) 2024-Present Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# This file implements a single-producer multi-consumer
# FIFO task queue for work-stealing schedulers with
#
# - steal one task
# - steal half the tasks
# - fairness optimized
# - 1 LIFO slot for locality optimization, message-passing use-cases
#
# Reading
# - https://nim-lang.org/blog/2021/02/26/multithreading-flavors.html
# - https://assets.ctfassets.net/oxjq45e8ilak/48lwQdnyDJr2O64KUsUB5V/5d8343da0119045c4b26eb65a83e786f/100545_516729073_DMITRII_VIUKOV_Go_scheduler_Implementing_language_with_lightweight_concurrency.pdf
#
# Tradeoffs considered
# - LIFO optimizes for cache-reuse (compute)
# - FIFO avoids starvation and optimizes for fairness and latency (IO)
# - The queue is fixed-size so there needs to be an overflow mechanism
# - The queue can handle steal one or half tasks without cooperation of taskqueue owner (unlike Weave work-sharing or Constantine stealOne only)
# - Stealing and dequeuing occurs from the same end of the queue, so there is extra contention compared to a classic work-stealing dequeue

{.push raises: [], checks: off.} # No exceptions in a multithreading datastructure

import
  std/atomics,
  ../primitives/instrumentation,
  ./tasks_flowvars

const WVIO_TASKQUEUE_SIZE {.intdefine.} = 256
const MASK_MOD_SIZE=WVIO_TASKQUEUE_SIZE-1

type
  OverflowQueue = concept q, var mutq
    mutq.trySend(sink Task) is bool

  TaskQueue[OQ: OverflowQueue] = object
    ## Lockless single-producer multi-consumer FIFO queue
    front{.align: 64.}: Atomic[int]
    back: Atomic[int]
    lifoSlot{.align: 64.}: Atomic[ptr Task]
      ## A single-LIFO slot to optimize latency for actor-like pattern (i.e. workers spawning a task and blocking on it)
      ## This also help reclaim some throughput by scheduling a task that will likely
      ## reuse data already hot in cache for example when doing parallel divide-and-conquer
    buf{.align: 64.}: array[WVIO_TASKQUEUE_SIZE, ptr Task]
    overflowQueue: ptr OQ

proc enqueue*(tq: var Taskqueue, task: ptr Task, useLifo: bool) =
  ## Enqueue a task to the back
  ## if at capacity, enqueue in the overflow queue
  ##
  ## The queue owner is the only producer

  # Design decision:
  # Several frameworks are emptying half of the local queue and migrating that to the global queue.
  # This seems like the wrong approach to me
  # especially as every single one is transferring out tasks in the range [front, front+half]
  #
  # 1. It breaks fairness assumptions as the global queue is checked much less frequently.
  #    The front half now may be scheduled after new tasks.
  # 2. Then those tasks will be enqueued again in a local queue
  #    And if the queue becomes full again, they could be remigrated to the global queue.
  #    So we could design a workload with incredibly bad latency for such an approach
  # 3. Building the batch is done by a busy thread with a queue full of tasks,
  #    it should make progress on actual work instead of bookkeeping.
  #
  # Examples in Go, Rust and Zig:
  # - https://github.com/golang/go/blob/go1.25.5/src/runtime/proc.go#L7053-L7140
  # - https://github.com/tokio-rs/tokio/blob/tokio-1.48.0/tokio/src/runtime/scheduler/multi_thread/queue.rs#L186-L307
  # - https://github.com/kprotty/zap/blob/blog/src/thread_pool.zig#L604-L662
  #
  # Instead, the overflow queue should have a fast non-blocking multi-producer enqueue path,
  # which ideally is [wait-free](https://en.wikipedia.org/wiki/Non-blocking_algorithm).
  #
  # Note: Transfering out the recent tasks also have fairness issues
  #       and most annoyingly, it probably requires double-word CAS for synchronization
  #       instead of producer and consumers only needing to check tq.front to
  #       see if they were frontrunned.
  #       It also breaks simplifying invariants:
  #       - front and back are monotonically increasing
  #       - all dequeues occur from the front, all enqueues occur from the back

  var task = task
  if useLifo:
    while true:
      let oldLifo = tq.lifoSlot.load(moRelaxed)
      if not tq.lifoSlot.compareExchange(oldLifo, task, moAcquire, moRelease):
        # retry, lifo slot was stolen
        continue
      if oldLifo.isNil():
        return
      # `oldLifo` has been replaced in lifoSlot byt `task` and need to be enqueued to the back
      task = oldLifo
      break

  let f = tq.front.load(moAcquire)
  let b = tq.back.load(moRelaxed)

  if b-f < WVIO_TASKQUEUE_SIZE:
    tq.buf[b and MASK_MOD_SIZE] = task
    tq.b.store(b+1, moRelease)
  else:
    discard tq.overflowQueue.trySend(task)

proc dequeue*(tq: var TaskQueue): tuple[task: ptr Task, sameBudget: bool] =
  ## Dequeue a task either from the LIFO slot
  ## or from the front of the queue
  ##
  ## This reports in "sameBudget" if a task was pop-ed
  ## from the LIFO slot (i.e. a child from previous task)
  ## or not to track fairness of execution' resource usage
  ##
  ## Only the queue owner should call this.
  let task = tq.lifoSlot.load(moRelaxed)

  # Only the queue owner can add to the lifoSlot, so no need to loop this CAS
  if not task.isNil and tq.lifoSlot(task, nil, moAcquire, moRelease):
    return (task, true)

  while true:
    let f = tq.front.load(moAcquire)
    let b = tq.back.load(moRelaxed)
    if b-f == 0:
      return (nil, false)

    let task = tq.buf[f mod MASK_MOD_SIZE]
    if tq.front.compareExchange(f, f+1, moAcquire, moRelease):
      return (task, false)

proc stealOne*