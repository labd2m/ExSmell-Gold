```elixir
defmodule MyApp.Notifications.Dispatcher do
  @moduledoc """
  Central dispatcher for outbound notifications. Supports email, SMS, and
  push channels. Handles retries, deduplication, and delivery acknowledgment
  depending on the caller's requirements.
  """

  alias MyApp.Notifications.EmailAdapter
  alias MyApp.Notifications.SmsAdapter
  alias MyApp.Notifications.PushAdapter
  alias MyApp.Notifications.DeliveryReport
  alias MyApp.Notifications.DeduplicationStore

  @supported_channels [:email, :sms, :push]
  @max_retries 3

  def build_message(template, assigns) do
    %{
      template: template,
      assigns: assigns,
      idempotency_key: generate_key(template, assigns),
      created_at: DateTime.utc_now()
    }
  end

  def send(recipient, message, opts \\ []) when is_list(opts) do
    channel = Keyword.get(opts, :channel, :email)
    ack = Keyword.get(opts, :ack, :none)
    retries = Keyword.get(opts, :retries, @max_retries)

    unless channel in @supported_channels do
      raise ArgumentError, "unsupported channel: #{inspect(channel)}"
    end

    if DeduplicationStore.seen?(message.idempotency_key) do
      {:error, :duplicate}
    else
      result = attempt_send(channel, recipient, message, retries)

      case result do
        {:ok, provider_receipt} ->
          DeduplicationStore.mark_seen(message.idempotency_key)

          case ack do
            :none ->
              :ok

            :receipt ->
              {:ok, provider_receipt}

            :report ->
              report = %DeliveryReport{
                message_id: message.idempotency_key,
                channel: channel,
                recipient: recipient,
                provider_receipt: provider_receipt,
                delivered_at: DateTime.utc_now(),
                status: :delivered
              }

              {:ok, report}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def bulk_send(recipients, message, opts \\ []) do
    Enum.map(recipients, &send(&1, message, opts))
  end

  def schedule(recipient, message, deliver_at, opts \\ []) do
    %{
      recipient: recipient,
      message: message,
      deliver_at: deliver_at,
      opts: opts,
      scheduled_at: DateTime.utc_now()
    }
  end

  defp attempt_send(_channel, _recipient, _message, 0) do
    {:error, :max_retries_exceeded}
  end

  defp attempt_send(channel, recipient, message, retries_left) do
    adapter = channel_adapter(channel)

    case adapter.deliver(recipient, message) do
      {:ok, receipt} -> {:ok, receipt}
      {:error, :transient} -> attempt_send(channel, recipient, message, retries_left - 1)
      {:error, reason} -> {:error, reason}
    end
  end

  defp channel_adapter(:email), do: EmailAdapter
  defp channel_adapter(:sms), do: SmsAdapter
  defp channel_adapter(:push), do: PushAdapter

  defp generate_key(template, assigns) do
    content = "#{template}:#{inspect(assigns)}"
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end
end
```
