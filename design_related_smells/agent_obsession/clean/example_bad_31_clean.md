```elixir
defmodule Notifications.NotificationQueue do
  @moduledoc """
  Manages the queue of pending outbound notifications.
  """

  def start_link() do
    Agent.start_link(fn -> %{pending: [], sent: [], failed: []} end, name: __MODULE__)
  end

  def enqueue(pid, notification) do
    Agent.update(pid, fn state ->
      entry = Map.put(notification, :enqueued_at, DateTime.utc_now())
      %{state | pending: state.pending ++ [entry]}
    end)
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
    Agent.get_and_update(pid, fn state ->
      case state.pending do
        [] ->
          {:empty, state}

        [next | rest] ->
          dispatched = Map.put(next, :dispatched_at, DateTime.utc_now())
          {:ok, %{state | pending: rest, sent: [dispatched | state.sent]}}
      end
    end)
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
    Agent.update(pid, fn state ->
      updated_sent =
        Enum.map(state.sent, fn n ->
          if n.id == notification_id, do: Map.put(n, :confirmed_at, DateTime.utc_now()), else: n
        end)

      %{state | sent: updated_sent}
    end)
  end
end

defmodule Notifications.NotificationMetrics do
  @moduledoc """
  Exposes metrics and statistics about the notification pipeline.
  """

  def pending_count(pid) do
    Agent.get(pid, fn state -> length(state.pending) end)
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
