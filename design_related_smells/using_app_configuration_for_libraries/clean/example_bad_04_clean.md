```elixir
defmodule Notifier do
  @moduledoc """
  A notification dispatch library that routes messages to various
  channels (email, sms, push, webhook). Intended for use in alerting,
  transactional messaging, and marketing automation pipelines.
  """

  require Logger

  @valid_channels [:email, :sms, :push, :webhook]

  defmodule Notification do
    @enforce_keys [:recipient, :subject, :body]
    defstruct [:recipient, :subject, :body, :metadata, :priority]
  end

  defmodule DispatchResult do
    defstruct [:channel, :recipient, :status, :message_id, :sent_at]
  end

  @doc """
  Dispatches a notification to a recipient.

  The channel used and the rate limiting policy are determined by
  the application configuration.
  """
  def dispatch(%Notification{} = notification, overrides \\ []) do
    channel = Application.fetch_env!(:notifier, :default_channel)
    rate_limit = Application.fetch_env!(:notifier, :rate_limit_per_minute)

    unless channel in @valid_channels do
      raise ArgumentError, "Invalid channel configured: #{channel}"
    end

    if rate_limited?(notification.recipient, channel, rate_limit) do
      Logger.warning("Notifier: rate limit hit for #{notification.recipient} on #{channel}")
      {:error, :rate_limited}
    else
      perform_dispatch(channel, notification, overrides)
    end
  end

  @doc """
  Dispatches a batch of notifications, stopping on first hard failure.
  """
  def dispatch_batch(notifications, overrides \\ []) when is_list(notifications) do
    Enum.reduce_while(notifications, {:ok, []}, fn notif, {:ok, results} ->
      case dispatch(notif, overrides) do
        {:ok, result} -> {:cont, {:ok, [result | results]}}
        {:error, :rate_limited} = err -> {:halt, err}
        {:error, reason} ->
          Logger.error("Notifier: failed to dispatch to #{notif.recipient}: #{inspect(reason)}")
          {:cont, {:ok, results}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end

  @doc """
  Returns true if a recipient has been notified recently on a given channel.
  """
  def recently_notified?(recipient, channel) do
    rate_limit = Application.fetch_env!(:notifier, :rate_limit_per_minute)
    rate_limited?(recipient, channel, rate_limit)
  end

  # --- Private helpers ---

  defp rate_limited?(_recipient, _channel, :infinity), do: false

  defp rate_limited?(recipient, channel, limit) do
    key = "notifier:rate:#{channel}:#{recipient}"
    count = :ets.lookup_element(:notifier_rate_table, key, 2, 0)
    count >= limit
  end

  defp perform_dispatch(:email, notification, _opts) do
    Logger.info("Notifier: sending email to #{notification.recipient}")
    message_id = generate_message_id()
    {:ok, %DispatchResult{
      channel: :email,
      recipient: notification.recipient,
      status: :sent,
      message_id: message_id,
      sent_at: DateTime.utc_now()
    }}
  end

  defp perform_dispatch(:sms, notification, _opts) do
    Logger.info("Notifier: sending SMS to #{notification.recipient}")
    message_id = generate_message_id()
    {:ok, %DispatchResult{
      channel: :sms,
      recipient: notification.recipient,
      status: :sent,
      message_id: message_id,
      sent_at: DateTime.utc_now()
    }}
  end

  defp perform_dispatch(:push, notification, _opts) do
    Logger.info("Notifier: sending push to #{notification.recipient}")
    message_id = generate_message_id()
    {:ok, %DispatchResult{
      channel: :push,
      recipient: notification.recipient,
      status: :sent,
      message_id: message_id,
      sent_at: DateTime.utc_now()
    }}
  end

  defp perform_dispatch(:webhook, notification, opts) do
    url = Keyword.get(opts, :webhook_url, "")
    Logger.info("Notifier: posting webhook for #{notification.recipient} to #{url}")
    message_id = generate_message_id()
    {:ok, %DispatchResult{
      channel: :webhook,
      recipient: notification.recipient,
      status: :sent,
      message_id: message_id,
      sent_at: DateTime.utc_now()
    }}
  end

  defp generate_message_id do
    :crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower)
  end
end
```
