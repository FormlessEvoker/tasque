defmodule Tasque do
  @moduledoc """
  Tasque is an asynchronous concurrent task queue for Elixir.

  Each Tasque instance is a supervised pair — a `Task.Supervisor` and a
  `Tasque.Queue` GenServer — managed by `Tasque.Supervisor`.

  ## Usage

      # In your application supervision tree:
      children = [
        {Tasque, name: MyApp.Queue, max_concurrency: 5}
      ]

      # Enqueue work:
      {:ok, ref} = Tasque.queue_task(MyApp.Queue, fn -> expensive_work() end)

      # Either await the result:
      {:ok, result} = Tasque.await(ref)

      # Or receive it as a message:
      receive do
        {:tasque_result, ^ref, {:ok, result}} -> result
      end
  """

  @default_await_timeout 5_000

  @doc false
  def task_supervisor_name(name), do: :"#{name}.TaskSupervisor"

  @doc """
  Returns a child spec that starts a `Tasque.Supervisor` (which in turn
  starts a `Task.Supervisor` and `Tasque.Queue`).

  ## Options

    * `:name` — required. Used to register the queue GenServer.
      Internal processes derive their names from this.
    * `:max_concurrency` — max simultaneous tasks (default: 10)

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
  Enqueue a task. Returns immediately with `{:ok, ref}`.

  The task can be a zero-arity function or an `{module, function, args}` tuple.

  ## Options

    * `:timeout` — per-task execution timeout in ms, or `:infinity` (default: queue default)

  """
  @type task :: (-> any()) | {module(), atom(), [any()]}

  @spec queue_task(GenServer.server(), task(), keyword()) ::
          {:ok, ref :: reference()}
  def queue_task(queue, task, opts \\ []) do
    GenServer.call(queue, {:queue_task, task, opts})
  end

  @doc """
  Block until the task identified by `ref` completes or the timeout expires.
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
