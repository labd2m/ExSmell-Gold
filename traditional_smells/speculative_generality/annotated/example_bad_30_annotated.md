# Annotated Example — Speculative Generality

## Metadata

- **Smell name:** Speculative Generality
- **Expected smell location:** `send/4` in `Notifications.AlertSender`
- **Affected function(s):** `send/4`
- **Short explanation:** The `send/4` function accepts a `priority` parameter with a default of `:normal`. The intent was to route high-priority alerts through a faster delivery path and normal-priority through standard queuing. In practice, every call site passes only three arguments, always relying on the `:normal` default. No caller has ever passed `:high` or `:low`, making the parameter and its associated routing logic dead speculative flexibility.

---

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
  # VALIDATION: SMELL START - Speculative Generality
  # VALIDATION: This is a smell because the `priority` parameter with default `:normal` 
  # was added to allow callers to escalate critical alerts to `:high` for immediate 
  # dispatch. In practice, every call site in the codebase calls `send/3`, never 
  # providing a priority. As a result, the priority-based routing and the 
  # `@high_priority_channels` / `@low_priority_channels` module attributes exist 
  # solely to support a flexibility that was never exercised.
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
  # VALIDATION: SMELL END

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
