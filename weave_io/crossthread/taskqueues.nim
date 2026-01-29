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

const WVIO_TASKQUEUE_SIZE* {.intdefine.} = 256
const MASK_MOD_SIZE = WVIO_TASKQUEUE_SIZE - 1

type
  TaskQueue* = object
    ## Lockless single-producer multi-consumer FIFO queue
    front{.align: 64.}: Atomic[int]
    back: Atomic[int]
    lifoSlot{.align: 64.}: Atomic[ptr Task]
    ## A single-LIFO slot to optimize latency for actor-like pattern (i.e. workers spawning a task and blocking on it)
    ## This also help reclaim some throughput by scheduling a task that will likely
    ## reuse data already hot in cache for example when doing parallel divide-and-conquer
    buf{.align: 64.}: array[WVIO_TASKQUEUE_SIZE, ptr Task]

proc init*(tq: var TaskQueue) {.inline.} =
  ## Initialize the task queue
  tq.front.store(0, moRelaxed)
  tq.back.store(0, moRelaxed)
  tq.lifoSlot.store(nil, moRelaxed)

proc teardown*(tq: var TaskQueue) {.inline.} =
  ## Cleanup the task queue (currently a no-op, but provided for API consistency)
  discard

proc peek*(tq: var Taskqueue): int =
  ## Estimates the number of items pending in the channel
  ## In a SPMC setting
  ## - If called by the producer the true number might be less
  ##   due to consumers removing items concurrently.
  ## - If called by a consumer the true number is undefined
  ##   as other consumers also remove items concurrently and
  ##   the producer removes them concurrently.
  ##
  ## This is a non-locking operation.
  let # Handle race conditions
    b = tq.back.load(moRelaxed)  # Only the producer peeks in the threadpool so moRelaxed is enough
    f = tq.front.load(moAcquire)

  if b >= f:
    return b-f
  else:
    return 0

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
      var oldLifo = tq.lifoSlot.load(moRelaxed)
      if not tq.lifoSlot.compareExchange(oldLifo, task, moAcquire, moRelease):
        # retry, lifo slot was stolen
        continue
      if oldLifo.isNil():
        return
      # `oldLifo` has been replaced in lifoSlot byt `task` and need to be enqueued to the back
      task = oldLifo
      break

  let b = tq.back.load(moRelaxed)

  ascertain:
    let f = tq.front.load(moAcquire)
    b-f < WVIO_TASKQUEUE_SIZE
  tq.buf[b and MASK_MOD_SIZE] = task
  tq.back.store(b+1, moRelease)

proc enqueueBatch*(tq: var Taskqueue, taskList: ptr Task) =
  ## Enqueue from a linked list of tasks
  ## The slots left
  let b = tq.back.load(moRelaxed)
  ascertain:
    let f = tq.front.load(moAcquire)
    b-f < WVIO_TASKQUEUE_SIZE

  var current = taskList
  var i = 0
  while not current.isNil:
    let next = current.next.load(moRelaxed)
    tq.buf[b+i and MASK_MOD_SIZE] = current
    i += 1
    current = next

  tq.back.store(b+i, moRelease)
  postCondition: i <= WVIO_TASKQUEUE_SIZE

proc dequeue*(tq: var TaskQueue): tuple[task: ptr Task, sameBudget: bool] =
  ## Dequeue a task either from the LIFO slot
  ## or from the front of the queue
  ##
  ## This reports in "sameBudget" if a task was pop-ed
  ## from the LIFO slot (i.e. a child from previous task)
  ## or not to track fairness of execution' resource usage
  ##
  ## Only the queue owner should call this.
  var task = tq.lifoSlot.load(moRelaxed)

  # Only the queue owner can add to the lifoSlot, so no need to loop this CAS
  if not task.isNil and tq.lifoSlot.compareExchange(task, nil, moAcquire, moRelease):
    return (task, true)

  while true:
    var f = tq.front.load(moAcquire)
    let b = tq.back.load(moRelaxed)
    if b-f == 0:
      return (nil, false)

    let task = tq.buf[f mod MASK_MOD_SIZE]
    if tq.front.compareExchange(f, f+1, moAcquire, moRelease):
      return (task, false)

proc stealOne*(thiefID: int32, tq: var TaskQueue): ptr Task =
  ## Steal from `tq`
  while true:
    var f = tq.front.load(moAcquire)
    fence(moSequentiallyConsistent)
    let b = tq.back.load(moAcquire)

    if b <= f:
      return nil

    let task = tq.buf[f and MASK_MOD_SIZE]
    if tq.front.compareExchange(f, f + 1, moSequentiallyConsistent, moRelaxed):
      task.setThief(thiefID)
      return task

proc stealHalf*(thiefID: int32, tq: var TaskQueue, into: var TaskQueue): (ptr Task, int32) =
  ## Steal from `tq` copy into `into`.
  ## `into` MUST be the local queue owned by the caller of stealHalf
  preCondition: into.peek() == 0
  while true:
    var f = tq.front.load(moAcquire)
    fence(moSequentiallyConsistent)
    let b = tq.back.load(moAcquire)

    if b <= f:
      return (nil, 0)

    let count = b - f
    let halfCount = count - (count shr 1) # Rounding up

    if tq.front.compareExchange(f, f + halfCount, moSequentiallyConsistent, moRelaxed):
      if halfCount > 1:
        # Copy all tasks except the first to `into` queue.
        let into_back = into.back.load(moRelaxed)
        for i in 1 ..< halfCount:
          let task = tq.buf[(f + i) and MASK_MOD_SIZE]
          task.setThief(thiefID)
          into.buf[into_back+i-1 and MASK_MOD_SIZE] = task
        into.back.store(halfCount-1, moRelease)

      # Return the first task
      let task = tq.buf[f and MASK_MOD_SIZE]
      task.setThief(thiefID)
      return (task, int32 halfCount)

{.pop.}