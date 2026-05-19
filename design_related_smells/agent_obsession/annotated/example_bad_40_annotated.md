# Annotated Example – Bad Code

- **Smell name:** Agent Obsession
- **Expected smell location:** Modules `NotificationEnqueuer`, `NotificationDispatcher`, `NotificationLogger`, and `NotificationMetrics`
- **Affected functions:** `NotificationEnqueuer.push/2`, `NotificationDispatcher.dispatch_next/1`, `NotificationLogger.record_outcome/3`, `NotificationMetrics.summary/1`
- **Short explanation:** Each of the four modules calls Agent functions directly, spreading ownership of the notification queue state across the entire pipeline without a centralised state-owner module.

```elixir
defmodule NotificationQueue do
  @moduledoc "Shared Agent holding the notification pipeline state."

  def start_link(_opts \\ []) do
    initial = %{queue: :queue.new(), sent: [], failed: [], stats: %{total: 0, errors: 0}}
    Agent.start_link(fn -> initial end, name: __MODULE__)
  end

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :permanent}
  end
end

# VALIDATION: SMELL START - Agent Obsession
# VALIDATION: This is a smell because NotificationEnqueuer directly calls Agent.update
# to push items into the shared queue, taking ownership of the :queue Erlang data
# structure stored inside the Agent.
defmodule NotificationEnqueuer do
  @moduledoc "Adds outbound notifications to the pipeline queue."

  require Logger

  @supported_channels [:email, :sms, :push, :webhook]

  def push(agent, %{channel: channel, recipient: recipient, payload: payload} = notification)
      when channel in @supported_channels do
    entry = %{
      id: UUID.uuid4(),
      channel: channel,
      recipient: recipient,
      payload: payload,
      priority: Map.get(notification, :priority, :normal),
      enqueued_at: DateTime.utc_now(),
      attempts: 0
    }

    Agent.update(agent, fn state ->
      new_queue = :queue.in(entry, state.queue)
      %{state | queue: new_queue, stats: Map.update!(state.stats, :total, &(&1 + 1))}
    end)

    Logger.debug("Enqueued #{channel} notification for #{recipient}")
    {:ok, entry.id}
  end

  def push(_agent, %{channel: channel}) do
    {:error, "Unsupported channel: #{channel}"}
  end
end
# VALIDATION: SMELL END

# VALIDATION: SMELL START - Agent Obsession
# VALIDATION: This is a smell because NotificationDispatcher directly calls Agent.get
# and Agent.update to dequeue and process notifications, embedding queue-manipulation
# logic in a module that should only care about delivery, not state management.
defmodule NotificationDispatcher do
  @moduledoc "Pops and delivers the next notification from the queue."

  require Logger

  @max_retries 3

  def dispatch_next(agent) do
    case Agent.get(agent, fn state -> :queue.out(state.queue) end) do
      {:empty, _} ->
        :empty

      {{:value, notification}, rest_queue} ->
        Agent.update(agent, fn state -> %{state | queue: rest_queue} end)

        case deliver(notification) do
          :ok ->
            Logger.info("Dispatched #{notification.channel} to #{notification.recipient}")
            {:ok, notification.id}

          {:error, reason} ->
            if notification.attempts < @max_retries do
              retry = %{notification | attempts: notification.attempts + 1}

              Agent.update(agent, fn state ->
                %{state | queue: :queue.in_r(retry, state.queue)}
              end)

              Logger.warning("Requeueing #{notification.id}, attempt #{retry.attempts}")
              {:retry, notification.id}
            else
              Agent.update(agent, fn state ->
                %{
                  state
                  | failed: [%{notification | error: reason} | state.failed],
                    stats: Map.update!(state.stats, :errors, &(&1 + 1))
                }
              end)

              {:failed, notification.id}
            end
        end
    end
  end

  defp deliver(%{channel: :email, recipient: r, payload: p}) do
    Logger.debug("EMAIL → #{r}: #{inspect(p)}")
    :ok
  end

  defp deliver(%{channel: :sms, recipient: r, payload: p}) do
    Logger.debug("SMS → #{r}: #{inspect(p)}")
    :ok
  end

  defp deliver(_), do: {:error, :unsupported_channel}
end
# VALIDATION: SMELL END

# VALIDATION: SMELL START - Agent Obsession
# VALIDATION: This is a smell because NotificationLogger directly calls Agent.update
# to append outcome records to the :sent list inside the shared Agent, yet another
# module with intimate knowledge of the Agent's internal structure.
defmodule NotificationLogger do
  @moduledoc "Persists delivery outcomes for audit purposes."

  def record_outcome(agent, notification_id, outcome) do
    record = %{
      notification_id: notification_id,
      outcome: outcome,
      recorded_at: DateTime.utc_now()
    }

    Agent.update(agent, fn state ->
      case outcome do
        :sent -> %{state | sent: [record | state.sent]}
        :failed -> %{state | failed: [record | state.failed]}
        _ -> state
      end
    end)

    :ok
  end

  def last_outcomes(agent, n \\ 10) do
    Agent.get(agent, fn state ->
      all = state.sent ++ state.failed
      all |> Enum.sort_by(& &1.recorded_at, {:desc, DateTime}) |> Enum.take(n)
    end)
  end
end
# VALIDATION: SMELL END

# VALIDATION: SMELL START - Agent Obsession
# VALIDATION: This is a smell because NotificationMetrics directly calls Agent.get to
# read the internal :stats map and queue length, binding metric aggregation tightly to
# the Agent's internal data layout.
defmodule NotificationMetrics do
  @moduledoc "Exposes operational metrics from the notification pipeline."

  def summary(agent) do
    Agent.get(agent, fn state ->
      pending = :queue.len(state.queue)

      %{
        total_enqueued: state.stats.total,
        total_errors: state.stats.errors,
        pending_in_queue: pending,
        sent_count: length(state.sent),
        failed_count: length(state.failed),
        success_rate:
          if state.stats.total > 0 do
            Float.round((state.stats.total - state.stats.errors) / state.stats.total * 100, 1)
          else
            0.0
          end
      }
    end)
  end
end
# VALIDATION: SMELL END
```
