# Tasque — Design Specification

> *Tasque is a play on "Task Queue." Its theming is inspired by the Tarrasque from Dungeons & Dragons — a massive, unstoppable creature that devours everything in its path. Tasks are fed to the queue; the queue consumes them.*

---

## Overview

Tasque is an asynchronous concurrent task queue for Elixir. It allows callers to enqueue work — represented as anonymous functions or MFAs — and have that work executed asynchronously with a configurable maximum concurrency. Callers are notified of results via OTP message passing.

The primary design goals are:

1. **Low friction, high convenience** — the API should be easy to use correctly
2. **Proper OTP patterns** — supervision trees, linked processes, fault isolation
3. **Flexibility** — support both fire-and-forget and blocking use cases from the same primitive

---

## Core Concepts

### Task Queue (GenServer)

Each Tasque instance is a `GenServer` that maintains:

- An internal **FIFO queue** of task requests that have been submitted but not yet started
- A **pending map** of tasks that are currently executing, keyed by task ref
- A **`Task.Supervisor`** used to run tasks safely via `async_nolink`
- A **`max_concurrency`** setting controlling how many tasks may run simultaneously

Multiple independent queues can be run in the same application, each identified by a PID or a `:via` name.

### Task Representation

Tasks are accepted in the following forms and normalized internally to a zero-arity function:

| Input form | Example |
| --- | --- |
| Zero-arity function | `fn -> do_work() end` |
| MFA tuple | `{MyModule, :do_work, [arg1, arg2]}` |

Internally, MFAs are wrapped: `fn -> apply(m, f, a) end`.

### Refs

When a task is enqueued, the GenServer generates a stable `make_ref()` — the **caller ref** — which is immediately returned to the caller. This ref is decoupled from the internal `Task` ref used by the task supervisor.

The GenServer maintains an internal mapping of `task_ref → caller_ref` so it can match completed tasks back to the right caller and message.

---

## Internal State

```elixir
%{
  queue: :queue.new(),       # pending task requests not yet dispatched
  pending: %{},              # task_ref => %{caller: pid, caller_ref: ref, ...}
  max_concurrency: 10,       # maximum simultaneous running tasks
  task_supervisor: pid       # the Task.Supervisor for this queue instance
}
```

---

## Dispatch Logic

A private `dispatch/1` function is called:

- After every `queue_task` call
- After every task completes, errors, or times out

Dispatch behaviour:

1. **Queue is empty** → do nothing
2. **At max concurrency** → do nothing
3. **Slot available** → dequeue the next task, start it via `Task.Supervisor.async_nolink/2`, store it in `pending`, then call `dispatch` again (to greedily fill all available slots)

---

## Task Lifecycle & `handle_info`

Tasks are run under a `Task.Supervisor` via `async_nolink`, so a crashing task does not crash the queue.

Two messages can arrive in `handle_info`:

| Message | Meaning |
| --- | --- |
| `{task_ref, result}` | Task completed successfully |
| `{:DOWN, task_ref, :process, _pid, reason}` | Task exited (crash or normal exit after result) |

On a successful result (`{task_ref, result}`):

1. Look up `task_ref` in `pending`
2. Send `{:tasque_result, caller_ref, {:ok, result}}` to the caller
3. Call `Process.demonitor(task_ref, [:flush])` to discard the subsequent `:DOWN` message
4. Remove entry from `pending`
5. Call `dispatch`

On a `:DOWN` message with an abnormal reason:

1. Look up `task_ref` in `pending` (if found — it may have already been handled)
2. Send `{:tasque_result, caller_ref, {:exit, reason}}` to the caller
3. Remove entry from `pending`
4. Call `dispatch`

---

## Task Timeouts

- Tasks can have a **per-task timeout** specified at enqueue time, or fall back to a **queue-level default timeout**
- The queue uses `Process.send_after/3` to schedule a `{:tasque_timeout, caller_ref}` message to itself when a task starts running
- On receiving a timeout message, if the task is still in `pending`:
  1. Send `{:tasque_result, caller_ref, {:exit, :timeout}}` to the caller
  2. Kill the underlying task process
  3. Remove from `pending`
  4. Call `dispatch`

> **Note:** There is also an implicit *queue-wait timeout* question — how long can a task sit in the queue before being dispatched? This is deferred to a future version.

---

## Supervision Structure

Each Tasque queue is supervised as a pair:

```text
Tasque.Supervisor  (one_for_all)
├── Task.Supervisor   (the task runner for this queue)
└── Tasque.Queue      (the GenServer)
```

The `Task.Supervisor` is started first so its PID is available to the `Tasque.Queue` GenServer at init time.

The `Tasque.Supervisor` can itself be started as a child of the host application's supervision tree, or started dynamically.

---

## Caller Death / Orphaned Tasks

If the caller process dies before a task completes:

- The result message is sent to a dead PID — this is harmless (the message is silently dropped)
- For v1, tasks are **not cancelled** when the caller dies
- Future versions may monitor the caller and cancel/discard in-flight work on caller exit

---

## Public API

### `Tasque.queue_task/2,3`

Enqueues a single task. Returns immediately with a ref.

```elixir
@spec queue_task(queue :: GenServer.server(), task :: fun() | mfa(), opts :: keyword()) ::
  {:ok, ref :: reference()}

# Options:
#   timeout: pos_integer() | :infinity  (default: queue's configured default)
```

### `Tasque.await/1,2`

Blocks the calling process until the task with the given ref completes or the timeout expires.

```elixir
@spec await(ref :: reference(), timeout :: pos_integer() | :infinity) ::
  {:ok, result :: any()} | {:exit, reason :: any()} | {:error, :timeout}
```

On timeout, `await` returns `{:error, :timeout}` but does **not** cancel the task — the result message will eventually arrive in the caller's mailbox (unhandled).

### `Tasque.queue_many/2,3`

Enqueues multiple tasks at once. Returns a list of refs in the same order as the input tasks.

```elixir
@spec queue_many(queue :: GenServer.server(), tasks :: [fun() | mfa()], opts :: keyword()) ::
  {:ok, refs :: [reference()]}
```

### `Tasque.await_many/1,2`

Blocks until all given refs resolve or the timeout expires. Returns results in the same order as the refs.

```elixir
@spec await_many(refs :: [reference()], timeout :: pos_integer() | :infinity) ::
  [result :: {:ok, any()} | {:exit, any()} | {:error, :timeout}]
```

### `Tasque.queue_many_and_await/2,3`

Convenience combinator: enqueues all tasks and awaits all results. Equivalent to `queue_many` + `await_many`.

```elixir
@spec queue_many_and_await(
  queue :: GenServer.server(),
  tasks :: [fun() | mfa()],
  opts :: keyword()
) :: [result :: {:ok, any()} | {:exit, any()} | {:error, :timeout}]
```

---

## Result Message Format

All task results (success, crash, or timeout) are delivered to the caller as a single consistent message shape:

```elixir
{:tasque_result, ref :: reference(), result}
```

Where `result` is one of:

| Value | Meaning |
| --- | --- |
| `{:ok, value}` | Task completed successfully |
| `{:exit, reason}` | Task crashed or was killed |
| `{:exit, :timeout}` | Task exceeded its timeout |

---

## Use Cases

### A — Phoenix Controller (blocking)

The controller needs to rate-limit expensive work across all requests, but still return the result as the HTTP response. It uses Tasque to enforce concurrency, then awaits the result synchronously:

```elixir
def create(conn, params) do
  {:ok, ref} = Tasque.queue_task(:my_queue, fn -> do_expensive_thing(params) end)
  case Tasque.await(ref, 30_000) do
    {:ok, result}     -> send_resp(conn, 200, result)
    {:exit, _reason}  -> send_resp(conn, 500, "error")
    {:error, :timeout} -> send_resp(conn, 504, "timeout")
  end
end
```

### B — File Watcher / ETL (fire-and-forget with notification)

An event-driven process enqueues tasks and handles results asynchronously via `handle_info`:

```elixir
def handle_event(:file_detected, path, state) do
  {:ok, ref} = Tasque.queue_task(:etl_queue, fn -> load_file(path) end)
  {:ok, Map.put(state, ref, path)}
end

def handle_info({:tasque_result, ref, result}, state) do
  {path, state} = Map.pop(state, ref)
  handle_load_result(path, result)
  {:noreply, state}
end
```

### C — Batch Processing (enqueue all, await all)

A script-like scenario where all tasks are known upfront and the caller wants to block until everything is done:

```elixir
results =
  lines
  |> Enum.map(fn line -> fn -> insert_line(line) end end)
  |> then(&Tasque.queue_many_and_await(:db_queue, &1))
```

---

## Future Considerations (Out of Scope for v1)

- **Queue-wait timeout** — reject or expire tasks that wait too long to be dispatched
- **Task cancellation** — allow a caller to cancel an in-flight or queued task by ref
- **Caller monitoring** — cancel tasks when the caller process dies
- **Priority queuing** — dispatch higher-priority tasks before lower ones
- **Max queue size** — reject tasks with `{:error, :queue_full}` when the queue is saturated
- **Drain / graceful shutdown** — finish in-flight tasks before stopping, notify callers of tasks that never started
- **Backoff / retry** — automatic retry of failed tasks with configurable strategy
- **Metrics & telemetry** — emit `:telemetry` events for queue depth, task duration, error rates
