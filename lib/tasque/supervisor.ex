defmodule Tasque.Supervisor do
  @moduledoc """
  Internal supervisor that manages the process pair for a single Tasque
  instance: a `Task.Supervisor` and a `Tasque.Queue` GenServer.

  > #### Internal module {: .warning}
  >
  > This module is not part of the public API. Use `{Tasque, opts}` in your
  > supervision tree instead of starting this module directly.

  ## Supervision Strategy

  Uses `:one_for_all` — if either the `Task.Supervisor` or the
  `Tasque.Queue` crashes, both are restarted together. This is necessary
  because:

    * If the `Task.Supervisor` crashes, all in-flight tasks are lost and
      the queue's `:pending_refs` map would reference dead processes
    * If the `Tasque.Queue` crashes, the mapping between task refs and
      callers is lost, so in-flight task results could never be delivered

  Restarting both ensures the system returns to a clean, consistent state.

  ## Child Order

  The `Task.Supervisor` is started **before** the `Tasque.Queue` so that
  its registered name is available when `Tasque.Queue.init/1` runs.

  ## Process Naming

  Given a Tasque instance named `MyApp.Queue`, the following processes
  are registered:

  | Process | Registered Name |
  |---|---|
  | `Tasque.Supervisor` | `MyApp.Queue.Supervisor` |
  | `Task.Supervisor` | `MyApp.Queue.TaskSupervisor` |
  | `Tasque.Queue` | `MyApp.Queue` |
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
