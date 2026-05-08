<p align="center">
  <img src="branding/logo.png" alt="Tasque Logo" width="200" />
</p>

# Tasque

Tasque is an asynchronous, bounded-concurrency task queue for Elixir.
It lets you enqueue anonymous functions or MFA tuples, run them under a
supervised `Task.Supervisor`, and receive results back via standard OTP
messages.

Good use cases for this library include:

- Database queries
- Communications with external APIs or services

## Quick Start

Add a queue to your supervision tree:

```elixir
children = [
  {Tasque, name: MyApp.Queue, max_concurrency: 10}
]
```

Then enqueue work and await the result:

```elixir
{:ok, ref} = Tasque.queue_task(MyApp.Queue, fn -> expensive_work() end)
{:ok, result} = Tasque.await(ref)
```

## Timeouts

Per-task timeouts start when a task is enqueued, so they include both queue
wait time and execution time. If a timeout fires before dispatch, the task is
dropped from the queue and the caller receives `{:exit, :timeout}`. If it
fires while the task is running, the task process is terminated and the caller
receives the same timeout result.

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `tasque` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:tasque, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/tasque>.
