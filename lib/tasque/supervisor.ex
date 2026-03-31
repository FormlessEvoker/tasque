defmodule Tasque.Supervisor do
  @moduledoc """
  Internal supervisor that manages the `Task.Supervisor` and `Tasque.Queue`
  pair for a single Tasque instance. Uses `:one_for_all` strategy.

  Not part of the public API — use `Tasque.child_spec/1` to start.
  """
  use Supervisor

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    Supervisor.start_link(__MODULE__, opts, name: :"#{name}.Supervisor")
  end

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)

    children = [
      {Task.Supervisor, name: Tasque.task_supervisor_name(name)},
      {Tasque.Queue, opts}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
