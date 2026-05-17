```elixir
# ── file: lib/notifications/dispatcher.ex ───────────────────────────────────


defmodule Notifications.Dispatcher do
  @moduledoc """
  Core notification dispatch engine.
  Routes notification requests to the appropriate delivery channel.
  Defined in `lib/notifications/dispatcher.ex`.
  """

  alias Notifications.Channels.{Email, SMS, Push, Webhook}
  alias Notifications.Queue
  alias Notifications.RateLimit

  @supported_channels [:email, :sms, :push, :webhook]
  @max_retries 3

  @type notification :: %{
    id: String.t(),
    recipient_id: String.t(),
    channel: atom(),
    template: String.t(),
    payload: map(),
    priority: :high | :normal | :low,
    scheduled_at: DateTime.t() | nil,
    attempts: non_neg_integer()
  }

  @doc """
  Dispatch a notification immediately over the specified channel.
  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @spec dispatch(atom(), notification()) :: :ok | {:error, term()}
  def dispatch(channel, notification) when channel in @supported_channels do
    with :ok <- RateLimit.check(notification.recipient_id, channel) do
      case channel do
        :email -> Email.send(notification)
        :sms -> SMS.send(notification)
        :push -> Push.send(notification)
        :webhook -> Webhook.post(notification)
      end
    end
  end

  def dispatch(channel, _notification) do
    {:error, "Unsupported channel: #{channel}"}
  end

  @doc "Send the same notification to a list of recipient IDs."
  @spec broadcast(notification(), [String.t()]) :: %{ok: [String.t()], failed: [String.t()]}
  def broadcast(notification, recipient_ids) do
    results =
      Enum.map(recipient_ids, fn rid ->
        n = %{notification | recipient_id: rid, id: generate_id()}
        {rid, dispatch(notification.channel, n)}
      end)

    %{
      ok: for({rid, :ok} <- results, do: rid),
      failed: for({rid, {:error, _}} <- results, do: rid)
    }
  end

  @doc "Enqueue a notification for future delivery at `deliver_at`."
  @spec schedule(atom(), notification(), DateTime.t()) :: {:ok, String.t()} | {:error, term()}
  def schedule(channel, notification, deliver_at) do
    job = %{
      id: generate_id(),
      channel: channel,
      notification: Map.put(notification, :scheduled_at, deliver_at),
      deliver_at: deliver_at,
      attempts: 0
    }

    Queue.enqueue_scheduled(job)
  end

  @doc "Cancel a previously scheduled notification by its job ID."
  @spec cancel(String.t()) :: :ok | {:error, String.t()}
  def cancel(job_id) when is_binary(job_id) do
    case Queue.remove(job_id) do
      :ok -> :ok
      :not_found -> {:error, "Scheduled job not found: #{job_id}"}
    end
  end

  @doc "Re-enqueue a failed notification for retry if under the attempt limit."
  @spec retry(notification()) :: :ok | {:error, String.t()}
  def retry(%{attempts: attempts}) when attempts >= @max_retries do
    {:error, "Max retries (#{@max_retries}) exceeded"}
  end

  def retry(%{channel: channel} = notification) do
    updated = %{notification | attempts: notification.attempts + 1}
    dispatch(channel, updated)
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end
end


# ── file: lib/notifications/dispatcher_metrics.ex ─────────────────────────────────────────────────────


defmodule Notifications.Dispatcher do
  @moduledoc """
  Metrics and observability utilities for the notification dispatcher.
  """

  alias Notifications.MetricsStore

  @doc "Record a successful dispatch event."
  @spec record_success(atom(), String.t()) :: :ok
  def record_success(channel, recipient_id) do
    MetricsStore.increment("dispatcher.#{channel}.success", %{recipient: recipient_id})
  end

  @doc "Record a failed dispatch event with the failure reason."
  @spec record_failure(atom(), String.t(), term()) :: :ok
  def record_failure(channel, recipient_id, reason) do
    MetricsStore.increment("dispatcher.#{channel}.failure", %{
      recipient: recipient_id,
      reason: inspect(reason)
    })
  end

  @doc "Fetch aggregated dispatch stats for a given channel over the last N hours."
  @spec stats(atom(), non_neg_integer()) :: map()
  def stats(channel, hours \\ 24) do
    since = DateTime.add(DateTime.utc_now(), -hours * 3600, :second)

    MetricsStore.aggregate("dispatcher.#{channel}", since: since)
    |> Map.merge(%{channel: channel, window_hours: hours})
  end

  @doc "Return channels ordered by failure rate (descending) for the last 24 h."
  @spec top_failing_channels() :: [%{channel: atom(), failure_rate: float()}]
  def top_failing_channels do
    [:email, :sms, :push, :webhook]
    |> Enum.map(fn ch ->
      %{successes: s, failures: f} = stats(ch, 24)
      total = s + f
      rate = if total > 0, do: f / total, else: 0.0
      %{channel: ch, failure_rate: Float.round(rate, 4)}
    end)
    |> Enum.sort_by(& &1.failure_rate, :desc)
  end
end

```
