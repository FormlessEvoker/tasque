# Tasque

<p>
  <img src="branding/logo.png" alt="Tasque Logo" width="180" align="left" />
</p>

Tasque is an asynchronous, bounded-concurrency task queue for Elixir.
It lets you enqueue anonymous functions or MFA tuples, run them under a
supervised `Task.Supervisor`, and receive results back via standard OTP
messages.

It is a good fit when you need bounded parallelism, per-task timeouts,
and OTP-friendly result delivery without introducing a separate job
system.

<br clear="left" />

Good use cases for this library include:

- Database queries
- Communications with external APIs or services

## Why Tasque?

- Bounded concurrency with a simple FIFO queue
- Anonymous function and MFA task support
- Result delivery through regular OTP messages
- Per-task timeouts that cover both queue wait time and execution time
- Support for atom, `{:global, term}`, and `{:via, module, term}` queue names

## Quick Start

Add a queue to your supervision tree:

```elixir
children = [
  {Tasque, name: MyApp.Queue, max_concurrency: 10}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

Then enqueue work and await the result:

```elixir
{:ok, ref} = Tasque.queue_task(MyApp.Queue, fn -> expensive_work() end)
{:ok, result} = Tasque.await(ref)
```

You can also consume results directly from the caller mailbox:

```elixir
{:ok, ref} = Tasque.queue_task(MyApp.Queue, fn -> String.upcase("hello") end)

receive do
  {:tasque_result, ^ref, {:ok, result}} -> result
  {:tasque_result, ^ref, {:exit, reason}} -> {:error, reason}
end
```

## Task Formats

Tasks can be provided as either:

- A zero-arity function: `fn -> :work end`
- An MFA tuple: `{String, :upcase, ["hello"]}`

Invalid task formats return `{:error, :invalid_task}`.

## Result Format

Every task result is delivered to the calling process as:

```elixir
{:tasque_result, ref, outcome}
```

Where `outcome` is one of:

- `{:ok, result}` when the task completes successfully
- `{:exit, reason}` when the task crashes, exits, or times out

## Timeouts

Per-task timeouts start when a task is enqueued, so they include both queue
wait time and execution time. If a timeout fires before dispatch, the task is
dropped from the queue and the caller receives `{:exit, :timeout}`. If it
fires while the task is running, the task process is terminated and the caller
receives the same timeout result.

This is separate from `Tasque.await/2`, whose timeout only controls how long
the caller waits for a result. An `await/2` timeout does not cancel the task.

## Naming

The queue `:name` supports the standard OTP naming forms:

- An atom such as `MyApp.Queue`
- A global name such as `{:global, :my_queue}`
- A via tuple such as `{:via, Registry, {MyApp.Registry, "queue"}}`

Tasque derives matching companion names for its supervisor processes using the
same naming strategy.

## Examples

Different workloads often benefit from different concurrency limits. For
example, CPU-bound work is usually best capped near the number of schedulers,
while I/O-heavy work can often tolerate a higher limit:

```elixir
children = [
  {Tasque, name: MyApp.CpuQueue, max_concurrency: System.schedulers_online()},
  {Tasque, name: MyApp.IoQueue, max_concurrency: 50}
]
```

You can then route work to the appropriate queue:

```elixir
{:ok, image_ref} =
  Tasque.queue_task(MyApp.CpuQueue, fn -> render_thumbnail(image) end)

{:ok, api_ref} =
  Tasque.queue_task(MyApp.IoQueue, fn -> fetch_remote_profile(user_id) end, timeout: 5_000)

{:ok, thumbnail} = Tasque.await(image_ref)
{:ok, profile} = Tasque.await(api_ref)
```

MFA tasks work the same way:

```elixir
{:ok, ref} = Tasque.queue_task(MyApp.IoQueue, {String, :upcase, ["hello"]})
{:ok, "HELLO"} = Tasque.await(ref)
```

## Caveats

- Task results are delivered to the process that called `Tasque.queue_task/3`.
  If that caller exits before the task finishes, the result message is sent to
  a dead PID and is effectively lost.
- `Tasque.await/2` only controls how long the caller waits for a result. If it
  returns `{:error, :timeout}`, the task may still be queued or running, and
  its eventual `{:tasque_result, ref, outcome}` message will still arrive in
  the caller's mailbox.
- Per-task `:timeout` is different from `await/2` timeout. The queue-enforced
  timeout starts at enqueue time, includes queue wait time, and may expire
  before the task is ever dispatched.

## Installation

The package can be installed by adding `tasque` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:tasque, "~> 1.0.0"}
  ]
end
```

Documentation can be found at <https://hexdocs.pm/tasque>.
