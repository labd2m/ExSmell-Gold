# Annotated Example 05 — Agent Obsession

## Metadata

- **Smell name:** Agent Obsession
- **Expected smell location:** Modules `NotificationQueue`, `EmailDispatcher`, `SmsDispatcher`, and `NotificationLogger` all interact directly with the Agent PID
- **Affected functions:** `NotificationQueue.enqueue/3`, `EmailDispatcher.dispatch_next/1`, `SmsDispatcher.dispatch_next/1`, `NotificationLogger.flush_log/1`
- **Short explanation:** A shared notification queue is backed by an Agent, but four different modules each call `Agent.get/2` and `Agent.update/2` directly. This distributes the Agent access across the system with no single owner, causing inconsistent state updates and duplicated logic.

---

```elixir
defmodule NotificationQueue do
  @moduledoc """
  Manages a queue of pending outbound notifications.
  """

  def start_link do
    Agent.start_link(fn -> %{pending: [], dispatched: [], log: []} end)
  end

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because NotificationQueue directly calls
  # Agent.update/2 to push notifications into shared state. There is no
  # single module responsible for Agent access — any module with the PID
  # can read and write freely.
  def enqueue(pid, channel, payload) do
    Agent.update(pid, fn state ->
      notification = %{
        id: System.unique_integer([:positive]),
        channel: channel,
        payload: payload,
        queued_at: DateTime.utc_now(),
        status: :pending
      }
      Map.update!(state, :pending, fn q -> q ++ [notification] end)
    end)
    :ok
  end
  # VALIDATION: SMELL END

  def pending_count(pid) do
    Agent.get(pid, fn state -> length(state.pending) end)
  end
end

defmodule EmailDispatcher do
  @moduledoc """
  Dispatches email notifications from the queue.
  """

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because EmailDispatcher directly calls
  # Agent.get_and_update/2 to pop an item from the pending queue, duplicating
  # queue-management logic without going through any shared abstraction.
  def dispatch_next(pid) do
    Agent.get_and_update(pid, fn state ->
      case Enum.find(state.pending, fn n -> n.channel == :email end) do
        nil ->
          {:no_pending, state}
        notification ->
          remaining = List.delete(state.pending, notification)
          sent = Map.put(notification, :dispatched_at, DateTime.utc_now())
          new_state = %{state | pending: remaining, dispatched: [sent | state.dispatched]}
          {{:ok, notification}, new_state}
      end
    end)
  end
  # VALIDATION: SMELL END

  defp send_email(%{payload: %{to: to, subject: subject, body: body}}) do
    IO.puts("Sending email to #{to}: #{subject}\n#{body}")
    :ok
  end
end

defmodule SmsDispatcher do
  @moduledoc """
  Dispatches SMS notifications from the queue.
  """

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because SmsDispatcher also calls
  # Agent.get_and_update/2 directly, reproducing nearly the same pattern as
  # EmailDispatcher. Both modules independently manage the Agent's internal
  # queue structure, leading to tight coupling and duplication.
  def dispatch_next(pid) do
    Agent.get_and_update(pid, fn state ->
      case Enum.find(state.pending, fn n -> n.channel == :sms end) do
        nil ->
          {:no_pending, state}
        notification ->
          remaining = List.delete(state.pending, notification)
          sent = Map.put(notification, :dispatched_at, DateTime.utc_now())
          new_state = %{state | pending: remaining, dispatched: [sent | state.dispatched]}
          {{:ok, notification}, new_state}
      end
    end)
  end
  # VALIDATION: SMELL END

  defp send_sms(%{payload: %{to: phone, message: msg}}) do
    IO.puts("Sending SMS to #{phone}: #{msg}")
    :ok
  end
end

defmodule NotificationLogger do
  @moduledoc """
  Collects and flushes notification audit logs.
  """

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because NotificationLogger directly writes to
  # the Agent's :log key with Agent.update/2, mixing a logging concern into
  # the same Agent state used for queuing and dispatching — there is no
  # owner module enforcing what the Agent should contain.
  def flush_log(pid) do
    Agent.get_and_update(pid, fn state ->
      entries = state.dispatched |> Enum.map(fn n ->
        %{notification_id: n.id, channel: n.channel, at: n.dispatched_at}
      end)
      new_log = state.log ++ entries
      {new_log, %{state | log: new_log, dispatched: []}}
    end)
  end
  # VALIDATION: SMELL END

  def full_log(pid) do
    Agent.get(pid, fn state -> state.log end)
  end

  def stats(pid) do
    Agent.get(pid, fn state ->
      %{
        pending: length(state.pending),
        dispatched: length(state.dispatched),
        logged: length(state.log)
      }
    end)
  end
end
```
