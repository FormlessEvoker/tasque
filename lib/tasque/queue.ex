defmodule Tasque.Queue do
  @moduledoc """
  Internal GenServer that manages the task queue and dispatch loop.

  Not part of the public API — use `Tasque` instead.
  """
  use GenServer

  @default_max_concurrency 10

  @typep queued_entry :: %{
           caller: pid(),
           caller_ref: reference(),
           task_fun: (-> any()),
           timeout: pos_integer() | nil
         }

  @typep pending_entry :: %{
           caller: pid(),
           caller_ref: reference(),
           task_pid: pid(),
           timer_ref: reference() | nil
         }

  @typep state :: %{
           queue: :queue.queue(queued_entry()),
           pending: %{optional(reference()) => pending_entry()},
           max_concurrency: pos_integer(),
           task_supervisor: atom()
         }

  @doc false
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  # ---------------------------------------------------------------------------
  # Server callbacks
  # ---------------------------------------------------------------------------

  @impl true
  @spec init(keyword) :: {:ok, state()}
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    max_concurrency = Keyword.get(opts, :max_concurrency, @default_max_concurrency)

    {:ok,
     %{
       queue: :queue.new(),
       pending: %{},
       max_concurrency: max_concurrency,
       task_supervisor: Tasque.task_supervisor_name(name)
     }}
  end

  @impl true
  def handle_call({:queue_task, task, opts}, {caller_pid, _tag}, state) do
    timeout = Keyword.get(opts, :timeout)

    # A reference to send to the caller that is decoupled from the actual task reference
    caller_ref = make_ref()

    entry = %{
      caller: caller_pid,
      caller_ref: caller_ref,
      task_fun: normalize_task(task),
      timeout: timeout
    }

    new_state =
      state
      |> Map.put(:queue, :queue.in(entry, state.queue))
      |> dispatch()

    {:reply, {:ok, caller_ref}, new_state}
  end

  # Task completed successfully: {ref, result}
  @impl true
  def handle_info({task_ref, result}, state) when is_reference(task_ref) do
    case Map.pop(state.pending, task_ref) do
      {nil, _} ->
        {:noreply, state}

      {entry, new_pending} ->
        if entry.timer_ref, do: Process.cancel_timer(entry.timer_ref)
        Process.demonitor(task_ref, [:flush])
        send(entry.caller, {:tasque_result, entry.caller_ref, {:ok, result}})

        new_state =
          state
          |> Map.put(:pending, new_pending)
          |> dispatch()

        {:noreply, new_state}
    end
  end

  # Task crashed
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.pending, ref) do
      {nil, _} ->
        {:noreply, state}

      {entry, new_pending} ->
        if entry.timer_ref, do: Process.cancel_timer(entry.timer_ref)
        Process.demonitor(ref, [:flush])
        send(entry.caller, {:tasque_result, entry.caller_ref, {:exit, reason}})

        new_state =
          state
          |> Map.put(:pending, new_pending)
          |> dispatch()

        {:noreply, new_state}
    end
  end

  # Task timed out
  @impl true
  def handle_info({:tasque_timeout, task_ref}, state) do
    case Map.pop(state.pending, task_ref) do
      {nil, _} ->
        # Task already completed — late timeout message is a no-op
        {:noreply, state}

      {%{} = entry, new_pending} ->
        Task.Supervisor.terminate_child(state.task_supervisor, entry.task_pid)
        Process.demonitor(task_ref, [:flush])
        send(entry.caller, {:tasque_result, entry.caller_ref, {:exit, :timeout}})

        new_state =
          state
          |> Map.put(:pending, new_pending)
          |> dispatch()

        {:noreply, new_state}
    end
  end

  # Catch-all for unexpected messages (e.g., late :DOWN after timeout)
  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp dispatch(%{pending: pending, max_concurrency: max_concurrency} = state)
       when map_size(pending) >= max_concurrency, do: state

  defp dispatch(state) do
    case :queue.out(state.queue) do
      {:empty, _} ->
        state

      {{:value, entry}, new_queue} ->
        task = Task.Supervisor.async_nolink(state.task_supervisor, entry.task_fun)

        pending_entry = %{
          caller: entry.caller,
          caller_ref: entry.caller_ref,
          task_pid: task.pid,
          timer_ref: schedule_timeout(task.ref, entry.timeout)
        }

        pending = Map.put(state.pending, task.ref, pending_entry)

        state
        |> Map.put(:pending, pending)
        |> Map.put(:queue, new_queue)
        |> dispatch()
    end
  end

  defp normalize_task(fun) when is_function(fun, 0), do: fun

  defp normalize_task({m, f, a}) when is_atom(m) and is_atom(f) and is_list(a),
    do: fn -> apply(m, f, a) end

  defp schedule_timeout(_, :infinity), do: nil

  defp schedule_timeout(task_ref, timeout) when is_integer(timeout) and timeout > 0,
    do: Process.send_after(self(), {:tasque_timeout, task_ref}, timeout)

  defp schedule_timeout(_, _), do: nil
end
