# Annotated Example — GenServer Envy

- **Smell name:** GenServer Envy
- **Expected smell location:** `NotificationDispatcher` module — `Task` used with persistent bidirectional messaging
- **Affected function(s):** `start_dispatcher/1`, `dispatch_loop/2`, `acknowledge/2`
- **Short explanation:** A `Task` is meant for fire-and-forget async work. Here it maintains a loop, receives messages from multiple callers, and sends replies — a communication pattern that belongs in a `GenServer`.

```elixir
defmodule MyApp.NotificationDispatcher do
  @moduledoc """
  Dispatches notifications to users via email, SMS, and push channels.
  Tracks delivery acknowledgements and retries unconfirmed deliveries.
  """

  alias MyApp.{Mailer, SMSProvider, PushService}
  alias MyApp.Notifications.{Event, DeliveryLog}

  @channels [:email, :sms, :push]
  @ack_timeout_ms 5_000

  def start_dispatcher(config) do
    Task.start_link(fn ->
      initial_state = %{
        config: config,
        pending_acks: %{},
        delivered: [],
        failed: []
      }

      dispatch_loop(initial_state, 0)
    end)
  end

  # VALIDATION: SMELL START - GenServer Envy
  # VALIDATION: This is a smell because a Task is being used to implement a
  # persistent message-passing loop — receiving requests, sending replies, and
  # maintaining state across many interactions. This is exactly the purpose of
  # a GenServer; a Task should only perform a single async action.

  defp dispatch_loop(state, seq) do
    receive do
      {:dispatch, from, %Event{} = event} ->
        results =
          Enum.reduce(@channels, %{}, fn channel, acc ->
            if channel in state.config.enabled_channels do
              result = deliver(channel, event)
              Map.put(acc, channel, result)
            else
              acc
            end
          end)

        ref = make_ref()
        log = %DeliveryLog{ref: ref, event: event, results: results, seq: seq}
        send(from, {:dispatched, ref, results})

        new_pending = Map.put(state.pending_acks, ref, {log, DateTime.utc_now()})
        dispatch_loop(%{state | pending_acks: new_pending}, seq + 1)

      {:acknowledge, ref, channel} ->
        case Map.fetch(state.pending_acks, ref) do
          {:ok, {log, _ts}} ->
            updated_log = %{log | acked_channels: [channel | Map.get(log, :acked_channels, [])]}
            all_acked? = Enum.all?(state.config.enabled_channels, &(&1 in updated_log.acked_channels))

            new_state =
              if all_acked? do
                %{
                  state
                  | pending_acks: Map.delete(state.pending_acks, ref),
                    delivered: [updated_log | state.delivered]
                }
              else
                %{state | pending_acks: Map.put(state.pending_acks, ref, {updated_log, DateTime.utc_now()})}
              end

            dispatch_loop(new_state, seq)

          :error ->
            dispatch_loop(state, seq)
        end

      {:get_status, from} ->
        status = %{
          pending: map_size(state.pending_acks),
          delivered: length(state.delivered),
          failed: length(state.failed)
        }
        send(from, {:status, status})
        dispatch_loop(state, seq)

      {:sweep_timeouts} ->
        now = DateTime.utc_now()

        {expired, still_pending} =
          Enum.split_with(state.pending_acks, fn {_ref, {_log, ts}} ->
            DateTime.diff(now, ts, :millisecond) > @ack_timeout_ms
          end)

        new_failed = Enum.map(expired, fn {_ref, {log, _ts}} -> log end)

        new_state = %{
          state
          | pending_acks: Map.new(still_pending),
            failed: new_failed ++ state.failed
        }

        dispatch_loop(new_state, seq)

      :stop ->
        :ok
    end
  end

  # VALIDATION: SMELL END

  def acknowledge(dispatcher_pid, ref, channel) do
    send(dispatcher_pid, {:acknowledge, ref, channel})
  end

  def get_status(dispatcher_pid) do
    send(dispatcher_pid, {:get_status, self()})

    receive do
      {:status, status} -> {:ok, status}
    after
      3_000 -> {:error, :timeout}
    end
  end

  defp deliver(:email, event), do: Mailer.send(event)
  defp deliver(:sms, event), do: SMSProvider.send(event)
  defp deliver(:push, event), do: PushService.send(event)
end
```
