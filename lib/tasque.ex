defmodule Tasque do
  @moduledoc """
  An asynchronous, bounded-concurrency task queue for Elixir.

  Tasque lets you enqueue work — anonymous functions or MFA tuples — and
  execute it asynchronously under a supervised `Task.Supervisor`, with a
  configurable ceiling on simultaneous tasks. Results are delivered back to
  the caller via plain OTP messages, so you can choose between blocking
  (`await/2`) and non-blocking (selective `receive`) consumption styles.

  ## Quick Start

  Add a Tasque instance to your application's supervision tree:

      children = [
        {Tasque, name: MyApp.Queue, max_concurrency: 10}
      ]

      Supervisor.start_link(children, strategy: :one_for_one)

  Then enqueue work from anywhere:

      {:ok, ref} = Tasque.queue_task(MyApp.Queue, fn -> expensive_work() end)

      # Block until the result arrives (or timeout):
      {:ok, result} = Tasque.await(ref)

  ## Result Format

  Every task result is delivered as a `{:tasque_result, ref, outcome}` message
  to the process that called `queue_task/3`. The `outcome` is one of:

  | Outcome | Meaning |
  |---|---|
  | `{:ok, result}` | Task completed successfully and returned `result` |
  | `{:exit, reason}` | Task crashed, was killed, or timed out |

  When using `await/2`, the outcome tuple is returned directly.

  ## Task Formats

  Tasks can be provided as either a zero-arity anonymous function or an
  MFA tuple. MFA tuples are normalized internally to `fn -> apply(m, f, a) end`.

      # Anonymous function
      Tasque.queue_task(queue, fn -> String.upcase("hello") end)

      # MFA tuple
      Tasque.queue_task(queue, {String, :upcase, ["hello"]})

  ## Supervision Architecture

  Each Tasque instance starts a small supervision subtree:

      Tasque.Supervisor (:one_for_all)
      ├── Task.Supervisor   — runs tasks via async_nolink
      └── Tasque.Queue      — GenServer managing the FIFO queue

  The `:one_for_all` strategy ensures that if either child crashes, both
  are restarted together, keeping the system in a consistent state. The
  `Task.Supervisor` starts first so its name is available to `Tasque.Queue`
  at init time.

  ## Concurrency Control

  When the number of in-flight tasks is below `:max_concurrency`, enqueued
  work is dispatched immediately. Once the limit is reached, tasks wait in
  a FIFO queue and are dispatched as running tasks complete, crash, or
  time out — each of these events frees a concurrency slot.

  ## Fault Isolation

  Tasks run under `Task.Supervisor.async_nolink/2`, so a crashing task:

    * Does **not** crash the queue GenServer
    * Does **not** affect other concurrently running tasks
    * Produces an `{:exit, reason}` result delivered to the original caller
    * Frees its concurrency slot, allowing the next queued task to dispatch

  ## Per-Task Timeouts

  You can set a timeout on individual tasks at enqueue time:

      Tasque.queue_task(queue, fn -> slow_work() end, timeout: 5_000)

  If the task does not complete within the timeout:

    1. The task process is killed (`Task.Supervisor.terminate_child/2`)
    2. `{:exit, :timeout}` is delivered to the caller
    3. The concurrency slot is freed

  Pass `timeout: :infinity` to disable the per-task timeout. If no
  `:timeout` option is given, the task runs without a timeout.

  > #### Await timeout vs. task timeout {: .warning}
  >
  > `Tasque.await/2`'s timeout controls how long the *caller* is willing
  > to wait. It does **not** cancel the task — the task will continue
  > running, its result will still be delivered to the caller's mailbox,
  > and it will still occupy a concurrency slot.
  >
  > The `:timeout` option on `queue_task/3` is enforced by the queue
  > itself and **does** kill the task process.

  ## Multiple Queues

  You can run independent queues with different concurrency limits for
  different workload categories:

      children = [
        {Tasque, name: MyApp.CpuQueue, max_concurrency: System.schedulers_online()},
        {Tasque, name: MyApp.IoQueue,  max_concurrency: 50}
      ]

  Each queue maintains its own task supervisor, dispatch loop, and
  concurrency budget.

  ## Caller Refs

  The reference returned by `queue_task/3` is a **caller ref** — a
  `make_ref()` created by the queue GenServer and decoupled from the
  internal `Task` ref used by the task supervisor. This means:

    * The caller never holds a direct reference to the underlying task process
    * Refs are unique per enqueue call, even if the same function is submitted twice
    * The queue maintains the mapping from internal task refs to caller refs

  ## Edge Cases

    * **Caller dies before task completes** — the result message is sent
      to a dead PID and silently dropped. The task still runs to completion
      (or timeout) and the concurrency slot is freed normally.

    * **Await times out** — `await/2` returns `{:error, :timeout}` but
      the task keeps running. The `{:tasque_result, ref, outcome}` message
      will eventually arrive in the caller's mailbox. You can call `await/2`
      again with the same ref to retrieve it, or use a selective `receive`.
  """

  @default_await_timeout 5_000

  @doc false
  def task_supervisor_name(name), do: :"#{name}.TaskSupervisor"

  @doc """
  Returns a child specification for starting a Tasque instance under a supervisor.

  This is invoked automatically when you use `{Tasque, opts}` tuple syntax in
  a supervision tree.

  ## Options

    * `:name` (required) — an atom used to register the `Tasque.Queue`
      GenServer. Internal processes derive their names from this value.
      For example, if `name: MyApp.Queue` is provided, the derived names
      are `MyApp.Queue.TaskSupervisor` and `MyApp.Queue.Supervisor`.

    * `:max_concurrency` — the maximum number of tasks that may execute
      simultaneously. Defaults to `10`.

  ## Examples

  As part of a supervision tree:

      children = [
        {Tasque, name: MyApp.Queue, max_concurrency: 5}
      ]

  Or build the spec manually:

      Tasque.child_spec(name: MyApp.Queue, max_concurrency: 5)
      #=> %{id: MyApp.Queue, start: {Tasque.Supervisor, :start_link, [[name: MyApp.Queue, max_concurrency: 5]]}, type: :supervisor}

  """
  def child_spec(opts) do
    name = Keyword.fetch!(opts, :name)

    %{
      id: name,
      start: {Tasque.Supervisor, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc """
  Enqueue a task for asynchronous execution. Returns immediately with
  `{:ok, ref}`, where `ref` is a unique reference for tracking the result.

  The result will be delivered as a `{:tasque_result, ref, outcome}` message
  to the calling process. Use `await/2` or a selective `receive` to consume it.

  ## Task Formats

    * **Zero-arity function** — `fn -> :work end`
    * **MFA tuple** — `{Module, :function, [args]}`

  ## Options

    * `:timeout` — per-task execution timeout in milliseconds, or
      `:infinity`. When a task exceeds its timeout, it is killed and
      `{:exit, :timeout}` is delivered. If omitted, no timeout is applied.

  ## Examples

      iex> {:ok, _} = Tasque.Supervisor.start_link(name: Tasque.QueueTaskDoc, max_concurrency: 5)
      iex> {:ok, ref} = Tasque.queue_task(Tasque.QueueTaskDoc, fn -> 1 + 1 end)
      iex> is_reference(ref)
      true
      iex> Tasque.await(ref)
      {:ok, 2}

  With an MFA tuple:

      iex> {:ok, _} = Tasque.Supervisor.start_link(name: Tasque.QueueTaskMfaDoc, max_concurrency: 5)
      iex> {:ok, ref} = Tasque.queue_task(Tasque.QueueTaskMfaDoc, {String, :upcase, ["hello"]})
      iex> Tasque.await(ref)
      {:ok, "HELLO"}

  With a per-task timeout:

      iex> {:ok, _} = Tasque.Supervisor.start_link(name: Tasque.QueueTaskTimeoutDoc, max_concurrency: 5)
      iex> {:ok, ref} = Tasque.queue_task(Tasque.QueueTaskTimeoutDoc, fn -> Process.sleep(:infinity) end, timeout: 50)
      iex> receive do
      ...>   {:tasque_result, ^ref, outcome} -> outcome
      ...> after
      ...>   1_000 -> :never_arrived
      ...> end
      {:exit, :timeout}

  """
  @type task :: (-> any()) | {module(), atom(), [any()]}

  @spec queue_task(GenServer.server(), task(), keyword()) ::
          {:ok, ref :: reference()}
  def queue_task(queue, task, opts \\ []) do
    GenServer.call(queue, {:queue_task, task, opts})
  end

  @doc """
  Block the calling process until the task identified by `ref` completes
  or the timeout expires.

  Returns the task outcome directly:

    * `{:ok, result}` — task completed successfully
    * `{:exit, reason}` — task crashed or was killed (including `:timeout`)
    * `{:error, :timeout}` — the *await* timed out (task is still running)

  The default timeout is #{@default_await_timeout} ms.

  > #### Important {: .info}
  >
  > An await timeout does **not** cancel the task. The task continues
  > running, occupies its concurrency slot, and its result message will
  > still arrive in the caller's mailbox. If you need to enforce a hard
  > deadline, use the `:timeout` option on `queue_task/3` instead.

  ## Examples

      iex> {:ok, _} = Tasque.Supervisor.start_link(name: Tasque.AwaitDoc, max_concurrency: 5)
      iex> {:ok, ref} = Tasque.queue_task(Tasque.AwaitDoc, fn -> 42 end)
      iex> Tasque.await(ref)
      {:ok, 42}

  With a custom timeout:

      iex> {:ok, _} = Tasque.Supervisor.start_link(name: Tasque.AwaitTimeoutDoc, max_concurrency: 5)
      iex> {:ok, ref} = Tasque.queue_task(Tasque.AwaitTimeoutDoc, fn -> Process.sleep(:infinity) end)
      iex> Tasque.await(ref, 50)
      {:error, :timeout}

  """
  @spec await(ref :: reference(), timeout :: pos_integer() | :infinity) ::
          {:ok, result :: any()} | {:exit, reason :: any()} | {:error, :timeout}
  def await(ref, timeout \\ @default_await_timeout) do
    receive do
      {:tasque_result, ^ref, result} -> result
    after
      timeout -> {:error, :timeout}
    end
  end
end
