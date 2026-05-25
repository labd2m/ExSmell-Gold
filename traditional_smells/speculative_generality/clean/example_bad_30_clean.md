```elixir
defmodule Notifications.AlertSender do
  @moduledoc """
  Delivers system and application alerts to configured recipients.

  Alerts are routed through priority-based queues: high-priority alerts
  bypass the standard queue and are dispatched immediately, while normal
  and low-priority alerts are batched and delivered on a scheduled interval.
  """

  require Logger

  alias Notifications.{Recipient, DeliveryQueue, ImmediateDispatcher, AlertLog}

  @high_priority_channels [:sms, :email, :push]
  @normal_priority_channels [:email, :push]
  @low_priority_channels [:email]

  @spec send(String.t(), String.t(), [Recipient.t()]) ::
          {:ok, [String.t()]} | {:error, atom()}
  def send(subject, body, recipients, priority \\ :normal) do
    channels = channels_for_priority(priority)

    with :ok <- validate_recipients(recipients),
         :ok <- validate_content(subject, body),
         {:ok, log_id} <- AlertLog.create(subject, body, priority, recipients) do
      results =
        Enum.flat_map(recipients, fn recipient ->
          Enum.map(channels, fn channel ->
            dispatch(subject, body, recipient, channel, priority, log_id)
          end)
        end)

      failed = Enum.filter(results, &match?({:error, _}, &1))

      if Enum.empty?(failed) do
        {:ok, Enum.map(results, fn {:ok, id} -> id end)}
      else
        Logger.warning("Some alert dispatches failed log_id=#{log_id}: #{inspect(failed)}")
        {:ok, Enum.map(results, fn {:ok, id} -> id end)}
      end
    end
  end

  defp channels_for_priority(:high), do: @high_priority_channels
  defp channels_for_priority(:normal), do: @normal_priority_channels
  defp channels_for_priority(:low), do: @low_priority_channels
  defp channels_for_priority(_), do: @normal_priority_channels

  defp dispatch(subject, body, recipient, channel, :high, log_id) do
    ImmediateDispatcher.dispatch(subject, body, recipient, channel, log_id)
  end

  defp dispatch(subject, body, recipient, channel, _priority, log_id) do
    DeliveryQueue.enqueue(subject, body, recipient, channel, log_id)
  end

  defp validate_recipients([]), do: {:error, :no_recipients}
  defp validate_recipients(recipients) when is_list(recipients), do: :ok
  defp validate_recipients(_), do: {:error, :invalid_recipients}

  defp validate_content(subject, _body) when byte_size(subject) == 0,
    do: {:error, :empty_subject}

  defp validate_content(_subject, body) when byte_size(body) == 0,
    do: {:error, :empty_body}

  defp validate_content(_subject, _body), do: :ok
end

defmodule Notifications.SystemMonitor do
  alias Notifications.{AlertSender, Recipient}

  def notify_ops_team(event_type, details) do
    recipients = Recipient.list_oncall()
    subject = "[SYSTEM] #{event_type}"
    body = "Event details:\n#{inspect(details)}"
    AlertSender.send(subject, body, recipients)
  end

  def notify_account_team(customer_id, event_type, details) do
    recipients = Recipient.list_for_account(customer_id)
    subject = "[ACCOUNT #{customer_id}] #{event_type}"
    body = inspect(details)
    AlertSender.send(subject, body, recipients)
  end
end
```
