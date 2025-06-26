# Tasque

Tasque is an asynchronous concurrent task queue for Elixir.
It can be used to manage background jobs, process tasks in parallel, and handle retries for failed jobs.

Good use cases for this library include:

- Database queries
- Commincations with external APIs or services

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
