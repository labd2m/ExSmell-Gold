```elixir
defmodule Notifications.RateLimitedDispatcher do
  @moduledoc """
  Wraps notification delivery with per-user, per-channel rate limiting.
  Delivery attempts that exceed the configured limit are rejected with
  `{:error, :rate_limited}` instead of being silently dropped or queued,
  giving callers a clear signal to back off or show a UI message.
  """

  alias Notifications.{Channel, Preference}

  @type user_id :: String.t()
  @type channel :: :email | :sms | :push
  @type event_type :: atom()
  @type dispatch_result :: :ok | {:error, :rate_limited | :channel_disabled | term()}

  @limits %{
    email: %{window_ms: :timer.hours(1), max_sends: 10},
    sms: %{window_ms: :timer.hours(1), max_sends: 5},
    push: %{window_ms: :timer.minutes(15), max_sends: 20}
  }

  @doc """
  Dispatches a notification to `user_id` on `channel` if within rate limits
  and the user has not opted out. Returns `:ok` or a typed error.
  """
  @spec dispatch(user_id(), channel(), event_type(), map()) :: dispatch_result()
  def dispatch(user_id, channel, event_type, payload)
      when is_binary(user_id) and is_atom(channel) and is_atom(event_type) and is_map(payload) do
    with :ok <- check_preference(user_id, channel, event_type),
         :ok <- check_rate_limit(user_id, channel) do
      deliver(user_id, channel, event_type, payload)
    end
  end

  @doc "Returns the current send count and limit for a user-channel pair."
  @spec usage(user_id(), channel()) :: %{count: non_neg_integer(), max: pos_integer(), window_ms: pos_integer()}
  def usage(user_id, channel) when is_binary(user_id) and is_atom(channel) do
    limit_config = Map.fetch!(@limits, channel)
    count = RateLimiter.TokenBucket.token_count(bucket_name(user_id, channel)) || 0
    max = limit_config.max_sends

    %{count: trunc(max - max(count, 0)), max: max, window_ms: limit_config.window_ms}
  end

  defp check_preference(user_id, channel, event_type) do
    if Notification.PreferenceStore.deliverable?(user_id, event_type, channel) do
      :ok
    else
      {:error, :channel_disabled}
    end
  end

  defp check_rate_limit(user_id, channel) do
    config = Map.fetch!(@limits, channel)
    bucket_config = %{capacity: config.max_sends, refill_per_second: config.max_sends * 1000 / config.window_ms}

    case RateLimiter.TokenBucket.consume(bucket_name(user_id, channel), bucket_config) do
      :ok -> :ok
      {:error, :rate_limited} -> {:error, :rate_limited}
    end
  end

  defp deliver(user_id, channel, event_type, payload) do
    channel_module = channel_for(channel)
    channel_module.deliver(user_id, Map.put(payload, :type, event_type))
  end

  defp channel_for(:email), do: Notifications.EmailChannel
  defp channel_for(:sms), do: Notifications.SMSChannel
  defp channel_for(:push), do: Notifications.PushChannel

  defp bucket_name(user_id, channel) do
    "notify:#{user_id}:#{channel}"
  end
end
```
