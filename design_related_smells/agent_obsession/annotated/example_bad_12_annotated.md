# Code Smell Example 12

- **Smell name:** Agent Obsession
- **Expected smell location:** Modules `NotificationQueue`, `DeliveryWorker`, `RetryPolicy`, and `NotificationMetrics`
- **Affected functions:** `NotificationQueue.enqueue/2`, `DeliveryWorker.process_next/1`, `RetryPolicy.mark_failed/3`, `NotificationMetrics.summary/1`
- **Short explanation:** The Agent used to track the notification queue state is accessed directly from four different modules. Each module independently reads or modifies the Agent, creating a fragmented ownership model where no single module enforces the data format or transition rules.

```elixir
defmodule NotificationQueue do
  @moduledoc """
  Manages a queue of outbound notifications backed by an Agent.
  """

  def new do
    {:ok, pid} = Agent.start_link(fn -> %{pending: [], failed: [], delivered: []} end)
    pid
  end

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because NotificationQueue directly writes to the Agent
  # while other unrelated modules (DeliveryWorker, RetryPolicy, NotificationMetrics)
  # also interact with the same Agent directly, spreading ownership.
  def enqueue(pid, notification) do
    entry = Map.put(notification, :enqueued_at, DateTime.utc_now())

    Agent.update(pid, fn state ->
      %{state | pending: state.pending ++ [entry]}
    end)
  end

  def pending_count(pid) do
    Agent.get(pid, fn state -> length(state.pending) end)
  end
  # VALIDATION: SMELL END
end

defmodule DeliveryWorker do
  @moduledoc """
  Pulls and delivers the next pending notification.
  """

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because DeliveryWorker directly calls Agent.get_and_update/2
  # to pop and transition notification state, bypassing any centralized queue interface.
  def process_next(pid) do
    Agent.get_and_update(pid, fn state ->
      case state.pending do
        [] ->
          {:empty, state}

        [next | rest] ->
          updated = %{state | pending: rest, delivered: [next | state.delivered]}
          {{:ok, next}, updated}
      end
    end)
    |> case do
      :empty -> {:error, :no_pending}
      {:ok, notification} -> attempt_delivery(notification)
    end
  end
  # VALIDATION: SMELL END

  defp attempt_delivery(%{channel: "email", to: to, body: body} = n) do
    IO.puts("Sending email to #{to}: #{body}")
    {:ok, n}
  end

  defp attempt_delivery(%{channel: "sms", to: to, body: body} = n) do
    IO.puts("Sending SMS to #{to}: #{body}")
    {:ok, n}
  end

  defp attempt_delivery(n), do: {:error, {:unknown_channel, n}}
end

defmodule RetryPolicy do
  @moduledoc """
  Handles failed notification delivery and applies retry logic.
  """

  @max_attempts 3

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because RetryPolicy directly updates the Agent state
  # for failed notifications, adding another direct Agent dependency outside the owner.
  def mark_failed(pid, notification, reason) do
    attempts = Map.get(notification, :attempts, 0) + 1

    Agent.update(pid, fn state ->
      if attempts >= @max_attempts do
        dead = Map.merge(notification, %{attempts: attempts, last_error: reason, dead: true})
        %{state | failed: [dead | state.failed]}
      else
        retryable = Map.merge(notification, %{attempts: attempts, last_error: reason})
        %{state | pending: state.pending ++ [retryable]}
      end
    end)
  end

  def requeue_all_failed(pid) do
    Agent.update(pid, fn state ->
      retryable = Enum.reject(state.failed, & &1[:dead])
      %{state | failed: Enum.filter(state.failed, & &1[:dead]), pending: state.pending ++ retryable}
    end)
  end
  # VALIDATION: SMELL END
end

defmodule NotificationMetrics do
  @moduledoc """
  Computes summary statistics for the notification pipeline.
  """

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because NotificationMetrics reaches directly into the
  # Agent to compute stats, instead of reading from a dedicated interface in the owning module.
  def summary(pid) do
    Agent.get(pid, fn state ->
      %{
        pending: length(state.pending),
        delivered: length(state.delivered),
        failed: length(state.failed),
        dead_letters: state.failed |> Enum.count(& &1[:dead])
      }
    end)
  end

  def delivery_rate(pid) do
    Agent.get(pid, fn state ->
      total = length(state.delivered) + length(state.failed)
      if total == 0, do: 0.0, else: length(state.delivered) / total
    end)
  end
  # VALIDATION: SMELL END
end
```
