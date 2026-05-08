defmodule Tasque.Queue do
  @moduledoc """
  Internal GenServer that manages the FIFO task queue, concurrency gating,
  and dispatch loop for a single Tasque instance.

  > #### Internal module {: .warning}
  >
  > This module is not part of the public API. Use the functions in `Tasque`
  > to interact with the queue. The implementation details documented here
  > are provided for contributors and the curious.

  ## State

  The GenServer maintains the following fields:

    * `:queue` — an Erlang `:queue` of task entries waiting to be dispatched
    * `:pending_refs` — a map of internal `task_ref => entry` for running tasks
    * `:queued_refs` — a map of `caller_ref => pid` for waiting tasks
    * `:cancelled_refs` — a map of `caller_ref => true` for tombstoned tasks
    * `:caller_to_task_ref` — a map of `caller_ref => task_ref` for fast timeout lookups
    * `:max_concurrency` — the upper bound on `map_size(pending_refs)`
    * `:task_supervisor` — the registered name of the companion `Task.Supervisor`

  ## Dispatch Algorithm

  The private `dispatch/1` function is called after every state-changing
  event (enqueue, completion, crash, timeout). It greedily fills available
  concurrency slots:

    1. If `map_size(pending_refs) >= max_concurrency`, return immediately
    2. If the queue is empty, return immediately
    3. Otherwise, dequeue the next entry, start it via
       `Task.Supervisor.async_nolink/2`, record it in `:pending_refs`, and
       recurse to fill any remaining slots

  ## Message Protocol

  Tasks are started with `async_nolink`, so results arrive as `handle_info`
  messages:

  | Message | Meaning | Action |
  |---|---|---|
  | `{task_ref, result}` | Successful completion | Deliver `{:ok, result}`, demonitor, free slot |
  | `{:DOWN, task_ref, :process, _, reason}` | Task crashed | Deliver `{:exit, reason}`, free slot |
  | `{:tasque_timeout, caller_ref}` | Per-task timeout fired | Kill task, deliver `{:exit, :timeout}`, free slot |

  A catch-all `handle_info/2` clause silently discards unexpected messages
  (e.g., a late `:DOWN` arriving after a timeout has already handled the task).

  ## Timeout Implementation

  When a task with a `:timeout` option is enqueued, the queue schedules
  a `{:tasque_timeout, caller_ref}` message to itself via
  `Process.send_after/3`. If the task is still in the queue when the
  timeout fires, it is tombstoned and skipped during dispatch. If it is
  currently running, it is killed. If the task completes before the timer
  fires, the timer is cancelled with `Process.cancel_timer/1`. Late
  timeout messages for already-completed tasks are harmless no-ops.
  """
  use GenServer

  @default_max_concurrency 10

  @typep task_fun :: (-> any())
  @typep fun_or_mfa() ::
           (-> any())
           | {module(), atom(), [any()]}

  @typep queued_entry :: %{
           caller: pid(),
           caller_ref: reference(),
           task_fun: task_fun(),
           timer_ref: reference() | nil
         }

  @typep pending_entry :: %{
           caller: pid(),
           caller_ref: reference(),
           task_pid: pid(),
           timer_ref: reference() | nil
         }

  @typep state :: %{
           queue: :queue.queue(queued_entry()),
           pending_refs: %{optional(reference()) => pending_entry()},
           queued_refs: %{optional(reference()) => pid()},
           cancelled_refs: %{optional(reference()) => true},
           caller_to_task_ref: %{optional(reference()) => reference()},
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
  @spec init(keyword()) :: {:ok, state()}
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    max_concurrency = Keyword.get(opts, :max_concurrency, @default_max_concurrency)

    if max_concurrency < 1 do
      raise ArgumentError, "max_concurrency must be at least 1, got: #{inspect(max_concurrency)}"
    end

    {:ok,
     %{
       queue: :queue.new(),
       pending_refs: %{},
       queued_refs: %{},
       cancelled_refs: %{},
       caller_to_task_ref: %{},
       max_concurrency: max_concurrency,
       task_supervisor: Tasque.task_supervisor_name(name)
     }}
  end

  @impl true
  @spec handle_call(
          {:queue_task, task :: fun_or_mfa(), opts :: keyword()},
          caller :: {pid(), any()},
          state()
        ) ::
          {:reply, {:ok, reference()}, state()}
          | {:reply, {:error, :invalid_task}, state()}
  def handle_call({:queue_task, task, opts}, {caller_pid, _tag}, state) do
    case normalize_task(task) do
      :error ->
        {:reply, {:error, :invalid_task}, state}

      task_fun ->
        timeout = Keyword.get(opts, :timeout)

        # A reference to send to the caller that is decoupled from the task reference
        caller_ref = make_ref()
        timer_ref = schedule_timeout(caller_ref, timeout)

        entry = %{
          caller: caller_pid,
          caller_ref: caller_ref,
          task_fun: task_fun,
          timer_ref: timer_ref
        }

        new_state =
          state
          |> Map.update!(:queued_refs, &Map.put(&1, caller_ref, caller_pid))
          |> Map.put(:queue, :queue.in(entry, state.queue))
          |> dispatch()

        {:reply, {:ok, caller_ref}, new_state}
    end
  end

  # Task completed successfully: {ref, result}
  @impl true
  @spec handle_info({reference(), any()}, state()) :: {:noreply, state()}
  def handle_info({task_ref, result}, state) when is_reference(task_ref) do
    case Map.pop(state.pending_refs, task_ref) do
      {nil, _} ->
        {:noreply, state}

      {entry, new_pending} ->
        if entry.timer_ref, do: Process.cancel_timer(entry.timer_ref)
        Process.demonitor(task_ref, [:flush])
        send(entry.caller, {:tasque_result, entry.caller_ref, {:ok, result}})

        new_state =
          state
          |> Map.put(:pending_refs, new_pending)
          |> update_in([:caller_to_task_ref], &Map.delete(&1, entry.caller_ref))
          |> dispatch()

        {:noreply, new_state}
    end
  end

  # Task crashed
  @impl true
  @spec handle_info({:DOWN, reference(), :process, pid(), reason :: any()}, state()) ::
          {:noreply, state()}
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.pending_refs, ref) do
      {nil, _} ->
        {:noreply, state}

      {entry, new_pending} ->
        if entry.timer_ref, do: Process.cancel_timer(entry.timer_ref)
        Process.demonitor(ref, [:flush])
        send(entry.caller, {:tasque_result, entry.caller_ref, {:exit, reason}})

        new_state =
          state
          |> Map.put(:pending_refs, new_pending)
          |> update_in([:caller_to_task_ref], &Map.delete(&1, entry.caller_ref))
          |> dispatch()

        {:noreply, new_state}
    end
  end

  # Task timed out
  @impl true
  @spec handle_info({:tasque_timeout, reference()}, state()) :: {:noreply, state()}
  def handle_info({:tasque_timeout, caller_ref}, state) do
    cond do
      Map.has_key?(state.queued_refs, caller_ref) ->
        # The task is still in the queue. We tombstone it.
        caller = Map.fetch!(state.queued_refs, caller_ref)
        send(caller, {:tasque_result, caller_ref, {:exit, :timeout}})

        new_state =
          state
          |> update_in([:queued_refs], &Map.delete(&1, caller_ref))
          |> update_in([:cancelled_refs], &Map.put(&1, caller_ref, true))

        {:noreply, new_state}

      task_ref = Map.get(state.caller_to_task_ref, caller_ref) ->
        # The task is currently running.
        entry = Map.fetch!(state.pending_refs, task_ref)
        Task.Supervisor.terminate_child(state.task_supervisor, entry.task_pid)
        Process.demonitor(task_ref, [:flush])
        send(entry.caller, {:tasque_result, entry.caller_ref, {:exit, :timeout}})

        new_state =
          state
          |> update_in([:pending_refs], &Map.delete(&1, task_ref))
          |> update_in([:caller_to_task_ref], &Map.delete(&1, caller_ref))
          |> dispatch()

        {:noreply, new_state}

      true ->
        # Task already completed (or unknown) — late timeout message is a no-op
        {:noreply, state}
    end
  end

  # Catch-all for unexpected messages (e.g., late :DOWN after timeout)
  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp dispatch(%{pending_refs: pending_refs, max_concurrency: max_concurrency} = state)
       when map_size(pending_refs) >= max_concurrency,
       do: state

  defp dispatch(state) do
    case :queue.out(state.queue) do
      {:empty, _} ->
        state

      {{:value, entry}, new_queue} ->
        if Map.has_key?(state.cancelled_refs, entry.caller_ref) do
          # Task timed out while in queue and was tombstoned. Drop it and recurse.
          state
          |> update_in([:cancelled_refs], &Map.delete(&1, entry.caller_ref))
          |> Map.put(:queue, new_queue)
          |> dispatch()
        else
          # Start the task
          task = Task.Supervisor.async_nolink(state.task_supervisor, entry.task_fun)

          pending_entry = %{
            caller: entry.caller,
            caller_ref: entry.caller_ref,
            task_pid: task.pid,
            timer_ref: entry.timer_ref
          }

          state
          |> update_in([:queued_refs], &Map.delete(&1, entry.caller_ref))
          |> update_in([:pending_refs], &Map.put(&1, task.ref, pending_entry))
          |> update_in([:caller_to_task_ref], &Map.put(&1, entry.caller_ref, task.ref))
          |> Map.put(:queue, new_queue)
          |> dispatch()
        end
    end
  end

  defp normalize_task(fun) when is_function(fun, 0), do: fun

  defp normalize_task({m, f, a}) when is_atom(m) and is_atom(f) and is_list(a),
    do: fn -> apply(m, f, a) end

  defp normalize_task(_), do: :error

  defp schedule_timeout(_, nil), do: nil

  defp schedule_timeout(_, :infinity), do: nil

  defp schedule_timeout(caller_ref, timeout) when is_integer(timeout) and timeout > 0,
    do: Process.send_after(self(), {:tasque_timeout, caller_ref}, timeout)

  defp schedule_timeout(_, timeout) do
    raise ArgumentError,
          "timeout must be a positive integer or :infinity, got: #{inspect(timeout)}"
  end
end
