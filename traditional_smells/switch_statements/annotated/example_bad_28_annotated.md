# Annotated Example — Switch Statements

## Metadata

- **Smell name:** Switch Statements
- **Expected smell location:** `NotificationDispatcher.resolve_adapter/1` and `NotificationDispatcher.max_body_length/1`
- **Affected functions:** `resolve_adapter/1`, `max_body_length/1`
- **Short explanation:** The same `case` branching over notification channel (`:email`, `:sms`, `:push`, `:webhook`) is duplicated in `resolve_adapter/1` and `max_body_length/1`. Adding a new channel requires updating both `case` expressions.

---

```elixir
defmodule NotificationDispatcher do
  @moduledoc """
  Dispatches notifications through the appropriate channel adapter
  (email, SMS, push, webhook) and enforces per-channel constraints
  such as body length limits and retry policies.
  """

  alias NotificationDispatcher.{
    EmailAdapter,
    SmsAdapter,
    PushAdapter,
    WebhookAdapter,
    Notification,
    DeliveryReceipt
  }

  @type channel :: :email | :sms | :push | :webhook

  @max_retries 3

  @spec dispatch(Notification.t()) :: {:ok, DeliveryReceipt.t()} | {:error, term()}
  def dispatch(%Notification{} = notification) do
    with :ok <- validate_body_length(notification),
         {:ok, adapter} <- resolve_adapter(notification.channel),
         {:ok, receipt} <- adapter.send(notification) do
      {:ok, receipt}
    end
  end

  @spec dispatch_with_retry(Notification.t()) :: {:ok, DeliveryReceipt.t()} | {:error, term()}
  def dispatch_with_retry(%Notification{} = notification, attempt \\ 1) do
    case dispatch(notification) do
      {:ok, receipt} ->
        {:ok, receipt}

      {:error, reason} when attempt < @max_retries ->
        backoff = :math.pow(2, attempt) |> round()
        Process.sleep(backoff * 1000)
        dispatch_with_retry(notification, attempt + 1)

      {:error, reason} ->
        {:error, {:max_retries_exceeded, reason}}
    end
  end

  @spec validate_body_length(Notification.t()) :: :ok | {:error, String.t()}
  defp validate_body_length(%Notification{channel: channel, body: body}) do
    limit = max_body_length(channel)

    if String.length(body) <= limit do
      :ok
    else
      {:error, "body exceeds #{limit} character limit for channel #{channel}"}
    end
  end

  # VALIDATION: SMELL START - Switch Statements
  # VALIDATION: This is a smell because the same case branching on `channel`
  # also appears in `max_body_length/1` below. Both enumerate :email, :sms,
  # :push, :webhook — any new channel must be added in two places.
  @spec resolve_adapter(channel()) :: {:ok, module()} | {:error, String.t()}
  defp resolve_adapter(channel) do
    case channel do
      :email   -> {:ok, EmailAdapter}
      :sms     -> {:ok, SmsAdapter}
      :push    -> {:ok, PushAdapter}
      :webhook -> {:ok, WebhookAdapter}
      other    -> {:error, "unsupported channel: #{other}"}
    end
  end
  # VALIDATION: SMELL END

  # VALIDATION: SMELL START - Switch Statements
  # VALIDATION: This is a smell because the same case branching on `channel`
  # already appeared in `resolve_adapter/1` above. The channel atoms are
  # fully repeated, so adding a new channel requires touching both case blocks.
  @spec max_body_length(channel()) :: integer()
  defp max_body_length(channel) do
    case channel do
      :email   -> 100_000
      :sms     -> 160
      :push    -> 256
      :webhook -> 10_000
    end
  end
  # VALIDATION: SMELL END

  @spec batch_dispatch([Notification.t()]) :: %{success: integer(), failure: integer()}
  def batch_dispatch(notifications) when is_list(notifications) do
    results = Enum.map(notifications, &dispatch/1)

    %{
      success: Enum.count(results, &match?({:ok, _}, &1)),
      failure: Enum.count(results, &match?({:error, _}, &1))
    }
  end

  @spec supported_channels() :: [channel()]
  def supported_channels, do: [:email, :sms, :push, :webhook]
end
```
