```elixir
defmodule Notifications.PushDispatcher do
  @moduledoc """
  Fans out push notifications to registered device tokens for a set of recipients.

  Token lookup, payload rendering, and delivery are separated into distinct
  responsibilities. Each delivery channel (APNS, FCM) is provided as an adapter
  passed per-call to support per-environment configuration.
  """

  alias Notifications.PushDispatcher.{
    TokenRegistry,
    PayloadRenderer,
    DeliveryResult,
    BatchResult
  }

  @type recipient_id :: String.t()
  @type push_opts :: [apns_adapter: module(), fcm_adapter: module(), dry_run: boolean()]

  @doc """
  Dispatches a push notification to all registered devices for a list of recipients.

  Returns a `BatchResult` summarising successes, failures, and invalid tokens.
  """
  @spec dispatch(String.t(), map(), [recipient_id()], push_opts()) :: BatchResult.t()
  def dispatch(template_name, assigns, recipient_ids, opts \\ [])
      when is_binary(template_name) and is_map(assigns) and is_list(recipient_ids) do
    apns = Keyword.get(opts, :apns_adapter, Notifications.Adapters.APNS)
    fcm = Keyword.get(opts, :fcm_adapter, Notifications.Adapters.FCM)
    dry_run = Keyword.get(opts, :dry_run, false)

    tokens = TokenRegistry.fetch_for_recipients(recipient_ids)

    results =
      tokens
      |> Enum.group_by(& &1.platform)
      |> Enum.flat_map(fn {platform, platform_tokens} ->
        dispatch_platform(platform, platform_tokens, template_name, assigns, apns, fcm, dry_run)
      end)

    BatchResult.from_delivery_results(results)
  end

  # --- private helpers ---

  defp dispatch_platform(:ios, tokens, template, assigns, apns, _fcm, dry_run) do
    {:ok, payload} = PayloadRenderer.render(:apns, template, assigns)
    Enum.map(tokens, &deliver_to_token(&1, payload, apns, dry_run))
  end

  defp dispatch_platform(:android, tokens, template, assigns, _apns, fcm, dry_run) do
    {:ok, payload} = PayloadRenderer.render(:fcm, template, assigns)
    Enum.map(tokens, &deliver_to_token(&1, payload, fcm, dry_run))
  end

  defp dispatch_platform(unknown, tokens, _template, _assigns, _apns, _fcm, _dry_run) do
    Enum.map(tokens, fn t ->
      DeliveryResult.error(t.token, t.recipient_id, "unsupported platform: #{unknown}")
    end)
  end

  defp deliver_to_token(token, _payload, _adapter, true) do
    DeliveryResult.ok(token.token, token.recipient_id, "dry_run")
  end

  defp deliver_to_token(token, payload, adapter, false) do
    case adapter.send(token.token, payload) do
      {:ok, message_id} ->
        DeliveryResult.ok(token.token, token.recipient_id, message_id)

      {:error, :invalid_token} ->
        TokenRegistry.mark_invalid(token.token)
        DeliveryResult.invalid_token(token.token, token.recipient_id)

      {:error, reason} ->
        DeliveryResult.error(token.token, token.recipient_id, reason)
    end
  end
end

defmodule Notifications.PushDispatcher.DeliveryResult do
  @moduledoc false

  @enforce_keys [:token, :recipient_id, :status]
  defstruct [:token, :recipient_id, :status, :message_id, :error]

  @type status :: :ok | :error | :invalid_token
  @type t :: %__MODULE__{}

  def ok(token, rid, mid), do: %__MODULE__{token: token, recipient_id: rid, status: :ok, message_id: mid}
  def error(token, rid, err), do: %__MODULE__{token: token, recipient_id: rid, status: :error, error: err}
  def invalid_token(token, rid), do: %__MODULE__{token: token, recipient_id: rid, status: :invalid_token}
end

defmodule Notifications.PushDispatcher.BatchResult do
  @moduledoc false

  alias Notifications.PushDispatcher.DeliveryResult

  defstruct succeeded: 0, failed: 0, invalid_tokens: 0, errors: []

  @type t :: %__MODULE__{}

  @spec from_delivery_results([DeliveryResult.t()]) :: t()
  def from_delivery_results(results) do
    Enum.reduce(results, %__MODULE__{}, fn
      %{status: :ok}, acc -> %{acc | succeeded: acc.succeeded + 1}
      %{status: :invalid_token}, acc -> %{acc | invalid_tokens: acc.invalid_tokens + 1}
      %{status: :error, error: e, token: t}, acc ->
        %{acc | failed: acc.failed + 1, errors: [{t, e} | acc.errors]}
    end)
  end
end
```
