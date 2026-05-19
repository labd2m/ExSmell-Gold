```elixir
defmodule NotificationQueue do
  @moduledoc """
  Manages a queue of pending outbound notifications.
  """

  def start_link do
    Agent.start_link(fn -> %{pending: [], dispatched: [], log: []} end)
  end

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

  def pending_count(pid) do
    Agent.get(pid, fn state -> length(state.pending) end)
  end
end

defmodule EmailDispatcher do
  @moduledoc """
  Dispatches email notifications from the queue.
  """

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

  defp send_email(%{payload: %{to: to, subject: subject, body: body}}) do
    IO.puts("Sending email to #{to}: #{subject}\n#{body}")
    :ok
  end
end

defmodule SmsDispatcher do
  @moduledoc """
  Dispatches SMS notifications from the queue.
  """

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

  defp send_sms(%{payload: %{to: phone, message: msg}}) do
    IO.puts("Sending SMS to #{phone}: #{msg}")
    :ok
  end
end

defmodule NotificationLogger do
  @moduledoc """
  Collects and flushes notification audit logs.
  """

  def flush_log(pid) do
    Agent.get_and_update(pid, fn state ->
      entries = state.dispatched |> Enum.map(fn n ->
        %{notification_id: n.id, channel: n.channel, at: n.dispatched_at}
      end)
      new_log = state.log ++ entries
      {new_log, %{state | log: new_log, dispatched: []}}
    end)
  end

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
