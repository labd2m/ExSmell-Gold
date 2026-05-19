# Code Smell: Agent Obsession

## Metadata

- **Smell name:** Agent Obsession
- **Expected smell location:** Modules `NotificationQueue`, `NotificationDispatcher`, `NotificationLogger`, and `NotificationMetrics`
- **Affected functions:** `NotificationQueue.enqueue/2`, `NotificationDispatcher.dispatch_next/1`, `NotificationLogger.record_sent/2`, `NotificationMetrics.pending_count/1`
- **Short explanation:** Four separate modules all interact directly with the same Agent managing notification state. The agent's internal structure (a map with `:pending`, `:sent`, and `:failed` keys) is assumed by all four modules independently, creating tight implicit coupling.

---

```elixir
defmodule Notifications.NotificationQueue do
  @moduledoc """
  Manages the queue of pending outbound notifications.
  """

  def start_link() do
    Agent.start_link(fn -> %{pending: [], sent: [], failed: []} end, name: __MODULE__)
  end

  def enqueue(pid, notification) do
    # VALIDATION: SMELL START - Agent Obsession
    # VALIDATION: This is a smell because NotificationQueue directly calls Agent.update/2
    # to push notifications into shared state. This direct interaction should be
    # encapsulated in a single module rather than spread across the system.
    Agent.update(pid, fn state ->
      entry = Map.put(notification, :enqueued_at, DateTime.utc_now())
      %{state | pending: state.pending ++ [entry]}
    end)
    # VALIDATION: SMELL END
  end

  def peek(pid) do
    Agent.get(pid, fn state -> List.first(state.pending) end)
  end

  def drain(pid) do
    Agent.get_and_update(pid, fn state ->
      {state.pending, %{state | pending: []}}
    end)
  end
end

defmodule Notifications.NotificationDispatcher do
  @moduledoc """
  Dispatches the next pending notification in the queue.
  """

  def dispatch_next(pid) do
    # VALIDATION: SMELL START - Agent Obsession
    # VALIDATION: This is a smell because NotificationDispatcher directly modifies
    # Agent state via Agent.get_and_update/2, independently managing the same
    # shared notification queue that NotificationQueue owns.
    Agent.get_and_update(pid, fn state ->
      case state.pending do
        [] ->
          {:empty, state}

        [next | rest] ->
          dispatched = Map.put(next, :dispatched_at, DateTime.utc_now())
          {:ok, %{state | pending: rest, sent: [dispatched | state.sent]}}
      end
    end)
    # VALIDATION: SMELL END
  end

  def retry_failed(pid) do
    Agent.update(pid, fn state ->
      retries = Enum.map(state.failed, &Map.put(&1, :retry, true))
      %{state | pending: state.pending ++ retries, failed: []}
    end)
  end
end

defmodule Notifications.NotificationLogger do
  @moduledoc """
  Records the outcome of dispatched notifications.
  """

  def record_failed(pid, notification_id, reason) do
    Agent.update(pid, fn state ->
      {to_fail, remaining_sent} =
        Enum.split_with(state.sent, fn n -> n.id == notification_id end)

      failed_entries =
        Enum.map(to_fail, &Map.merge(&1, %{failed_at: DateTime.utc_now(), reason: reason}))

      %{state | sent: remaining_sent, failed: state.failed ++ failed_entries}
    end)
  end

  def record_sent(pid, notification_id) do
    # VALIDATION: SMELL START - Agent Obsession
    # VALIDATION: This is a smell because NotificationLogger directly updates Agent state
    # to annotate sent notifications, making it a third module directly coupling to
    # the agent's internal structure.
    Agent.update(pid, fn state ->
      updated_sent =
        Enum.map(state.sent, fn n ->
          if n.id == notification_id, do: Map.put(n, :confirmed_at, DateTime.utc_now()), else: n
        end)

      %{state | sent: updated_sent}
    end)
    # VALIDATION: SMELL END
  end
end

defmodule Notifications.NotificationMetrics do
  @moduledoc """
  Exposes metrics and statistics about the notification pipeline.
  """

  def pending_count(pid) do
    # VALIDATION: SMELL START - Agent Obsession
    # VALIDATION: This is a smell because NotificationMetrics directly reads Agent state,
    # becoming a fourth module that independently knows the internal state map structure.
    Agent.get(pid, fn state -> length(state.pending) end)
    # VALIDATION: SMELL END
  end

  def delivery_rate(pid) do
    Agent.get(pid, fn state ->
      total = length(state.sent) + length(state.failed)
      if total == 0, do: 0.0, else: length(state.sent) / total * 100.0
    end)
  end

  def failed_notifications(pid) do
    Agent.get(pid, fn state -> state.failed end)
  end
end
```
