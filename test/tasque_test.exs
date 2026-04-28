defmodule TasqueTest do
  @moduledoc false
  use ExUnit.Case, async: true

  doctest Tasque

  describe "queue_task/3" do
    setup do
      %{queue: start_queue!()}
    end

    test "delivers {:ok, result} to caller on success", %{queue: queue} do
      {:ok, ref} = Tasque.queue_task(queue, fn -> 42 end)
      assert_receive {:tasque_result, ^ref, {:ok, 42}}, 500
    end

    @tag capture_log: true
    test "delivers {:exit, reason} when task raises", %{queue: queue} do
      {:ok, ref} = Tasque.queue_task(queue, fn -> raise "boom" end)

      assert_receive {:tasque_result, ^ref, {:exit, {%RuntimeError{message: "boom"}, _stack}}},
                     500
    end

    @tag capture_log: true
    test "delivers {:exit, reason} when task calls exit/1", %{queue: queue} do
      {:ok, ref} = Tasque.queue_task(queue, fn -> exit(:kaboom) end)
      assert_receive {:tasque_result, ^ref, {:exit, :kaboom}}, 500
    end

    test "accepts an MFA tuple", %{queue: queue} do
      {:ok, ref} = Tasque.queue_task(queue, {String, :upcase, ["hello"]})
      assert_receive {:tasque_result, ^ref, {:ok, "HELLO"}}, 500
    end

    test "sends appropriate results to respective callers", %{queue: queue} do
      Task.async(fn ->
        # Caller 1 task - returns quickly
        {:ok, r1} = Tasque.queue_task(queue, fn -> :from_caller_1 end)

        # Caller 2 task
        r2 =
          Task.async(fn ->
            {:ok, r} = Tasque.queue_task(queue, fn -> :from_caller_2 end)

            # Caller 2 should ONLY receive the result for its own request
            assert_receive {:tasque_result, ^r, {:ok, :from_caller_2}}, 500
            refute_receive {:tasque_result, _, {:ok, :from_caller_1}}, 100

            r
          end)
          |> Task.await()

        # Caller 1 should ONLY receive the result for its own request
        assert_receive {:tasque_result, ^r1, {:ok, :from_caller_1}}, 500
        refute_receive {:tasque_result, ^r1, {:ok, :from_caller_2}}, 100

        {r1, r2}
      end)
      |> Task.await()
    end

    # Is this inferred by the prior test?
    test "each call returns a unique ref", %{queue: queue} do
      refs =
        for _ <- 1..20 do
          {:ok, ref} = Tasque.queue_task(queue, fn -> :ok end)
          ref
        end

      assert length(Enum.uniq(refs)) == 20
    end
  end

  describe "await/1" do
    setup do
      %{queue: start_queue!()}
    end

    test "returns {:ok, result} on success", %{queue: queue} do
      {:ok, ref} = Tasque.queue_task(queue, fn -> 42 end)
      assert {:ok, 42} = Tasque.await(ref)
    end

    @tag capture_log: true
    test "returns {:exit, reason} on crash", %{queue: queue} do
      {:ok, ref} = Tasque.queue_task(queue, fn -> exit(:boom) end)
      assert {:exit, :boom} = Tasque.await(ref)
    end

    test "returns {:error, :timeout} when await times out", %{queue: queue} do
      {:ok, ref} = Tasque.queue_task(queue, fn -> Process.sleep(:infinity) end)
      assert {:error, :timeout} = Tasque.await(ref, 50)
    end

    test "await timeout does not cancel the task", %{queue: queue} do
      parent = self()

      {:ok, ref} =
        Tasque.queue_task(queue, fn ->
          send(parent, {:task_pid, self()})
          Process.sleep(200)
          :eventually_done
        end)

      assert {:error, :timeout} = Tasque.await(ref, 50)

      # The task is still running
      assert_receive {:task_pid, task_pid}, 500
      assert Process.alive?(task_pid)

      # The result message still arrives in our mailbox
      assert_receive {:tasque_result, ^ref, {:ok, :eventually_done}}, 500
    end

    # is this wise? 🤨
    test "works with :infinity timeout", %{queue: queue} do
      {:ok, ref} = Tasque.queue_task(queue, fn -> :fast end)
      assert {:ok, :fast} = Tasque.await(ref, :infinity)
    end
  end

  describe "Concurrency and Dispatch" do
    test "tasks dispatch immediately when under max concurrency" do
      queue = start_queue!(max_concurrency: 5)
      {:ok, _ref} = Tasque.queue_task(queue, blocking_task(self()))
      assert_receive {:started, _pid}, 500
    end

    test "dispatches up to max_concurrency immediately" do
      queue = start_queue!(max_concurrency: 3)

      for _ <- 1..3 do
        {:ok, _} = Tasque.queue_task(queue, blocking_task(self()))
      end

      {:ok, _} = Tasque.queue_task(queue, blocking_task(self()))

      for _ <- 1..3, do: assert_receive({:started, _}, 500)
      refute_receive {:started, _}, 100
    end

    test "tasks queue when at max concurrency" do
      queue = start_queue!(max_concurrency: 1)

      {:ok, _ref1} = Tasque.queue_task(queue, blocking_task(self()))
      assert_receive {:started, pid1}, 500

      {:ok, _ref2} = Tasque.queue_task(queue, blocking_task(self()))
      refute_receive {:started, _}, 100

      send(pid1, :continue)
      assert_receive {:started, _pid2}, 500
    end

    test "completing a task frees a slot and dispatches next queued task" do
      queue = start_queue!(max_concurrency: 1)

      {:ok, ref1} = Tasque.queue_task(queue, blocking_task(self()))
      assert_receive {:started, pid1}, 500

      {:ok, _ref2} = Tasque.queue_task(queue, blocking_task(self()))
      refute_receive {:started, _}, 100

      send(pid1, :continue)
      assert_receive {:tasque_result, ^ref1, {:ok, :done}}, 500
      assert_receive {:started, _pid2}, 500
    end

    @tag capture_log: true
    test "crashing task frees a slot" do
      queue = start_queue!(max_concurrency: 1)

      {:ok, ref1} = Tasque.queue_task(queue, fn -> raise "crash" end)
      assert_receive {:tasque_result, ^ref1, {:exit, _}}, 500

      {:ok, ref2} = Tasque.queue_task(queue, fn -> :after_crash end)
      assert_receive {:tasque_result, ^ref2, {:ok, :after_crash}}, 500
    end
  end

  describe "Task Timeouts" do
    setup do
      %{queue: start_queue!(max_concurrency: 5)}
    end

    test "per-task timeout delivers {:exit, :timeout}", %{queue: queue} do
      {:ok, ref} = Tasque.queue_task(queue, fn -> Process.sleep(:infinity) end, timeout: 50)
      assert_receive {:tasque_result, ^ref, {:exit, :timeout}}, 500
    end

    test "timed-out task process is killed", %{queue: queue} do
      parent = self()

      {:ok, ref} =
        Tasque.queue_task(
          queue,
          fn ->
            send(parent, {:task_pid, self()})
            Process.sleep(:infinity)
          end,
          timeout: 50
        )

      assert_receive {:task_pid, task_pid}, 500
      assert_receive {:tasque_result, ^ref, {:exit, :timeout}}, 500

      refute Process.alive?(task_pid)
    end

    test "timeout frees a concurrency slot" do
      queue = start_queue!(max_concurrency: 1)

      {:ok, ref1} =
        Tasque.queue_task(queue, fn -> Process.sleep(:infinity) end, timeout: 50)

      {:ok, _ref2} = Tasque.queue_task(queue, blocking_task(self()))

      assert_receive {:tasque_result, ^ref1, {:exit, :timeout}}, 500
      assert_receive {:started, _}, 500
    end

    test "infinity timeout means task never times out", %{queue: queue} do
      {:ok, ref} = Tasque.queue_task(queue, blocking_task(self()), timeout: :infinity)
      assert_receive {:started, pid}, 500

      refute_receive {:tasque_result, ^ref, {:exit, :timeout}}, 200

      send(pid, :continue)
      assert_receive {:tasque_result, ^ref, {:ok, :done}}, 500
    end
  end

  describe "Process Isolation" do
    @tag capture_log: true
    test "crashing task does not crash the queue", %{} do
      queue = start_queue!()

      {:ok, _ref} = Tasque.queue_task(queue, fn -> raise "kaboom" end)
      assert_receive {:tasque_result, _, {:exit, _}}, 500

      # Queue is still alive and accepting work
      {:ok, ref2} = Tasque.queue_task(queue, fn -> :still_alive end)
      assert_receive {:tasque_result, ^ref2, {:ok, :still_alive}}, 500
    end

    @tag capture_log: true
    test "crashing task does not affect other running tasks" do
      queue = start_queue!(max_concurrency: 2)

      {:ok, _ref_good} = Tasque.queue_task(queue, blocking_task(self()))
      assert_receive {:started, good_pid}, 500

      {:ok, ref_bad} = Tasque.queue_task(queue, fn -> raise "crash" end)
      assert_receive {:tasque_result, ^ref_bad, {:exit, _}}, 500

      # The good task is still running
      assert Process.alive?(good_pid)

      send(good_pid, :continue)
      assert_receive {:tasque_result, _, {:ok, :done}}, 500
    end

    @tag capture_log: true
    test "caller dying does not crash the queue" do
      queue = start_queue!()

      # Spawn a caller that enqueues a slow task then dies
      spawn(fn ->
        Tasque.queue_task(queue, fn -> Process.sleep(200) end)
        exit(:caller_gone)
      end)

      # Give time for the task to complete and the result to be sent to a dead pid
      Process.sleep(300)

      # Queue is still alive
      {:ok, ref} = Tasque.queue_task(queue, fn -> :after_caller_death end)
      assert_receive {:tasque_result, ^ref, {:ok, :after_caller_death}}, 500
    end
  end

  # region Helpers

  # Returns a zero-arity function that:
  #  1. Sends {:started, task_pid} to `notify_pid` so the test knows it's running
  #  2. Blocks until it receives :continue
  #  3. Returns :done
  # This gives us full control over exactly when async tasks finish
  defp blocking_task(notify_pid) do
    fn ->
      send(notify_pid, {:started, self()})

      receive do
        :continue -> :done
      end
    end
  end

  # Starts a Tasque queue as a supervised child of the test process.
  # Returns the registered name that addresses the Tasque.Queue GenServer.
  defp start_queue!(opts \\ []) do
    name = :"tasque_#{System.unique_integer([:positive])}"

    opts =
      opts
      |> Keyword.put_new(:max_concurrency, 10)
      |> Keyword.put(:name, name)

    start_supervised!({Tasque, opts})
    name
  end

  # endregion Helpers
end
