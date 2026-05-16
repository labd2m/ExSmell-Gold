```elixir
defmodule Integrations.WebhookParser do
  @moduledoc """
  Parses, validates, and normalizes inbound webhook payloads from third-party
  providers (Stripe, GitHub, Twilio). Supports multiple output modes for
  different pipeline stages.
  """

  alias Integrations.Schema.WebhookEvent

  @supported_providers ~w(stripe github twilio)

  @doc """
  Parses a raw JSON binary webhook payload.

  ## Arguments

    * `body` — Raw JSON binary from the HTTP request body.
    * `opts` — Keyword list of options.

  ## Options

    * `:provider` — Name of the originating provider (e.g., `"stripe"`).
      Used for provider-specific normalization.
    * `:raw` — When `true`, skips normalization and returns the decoded
      JSON map directly. Defaults to `false`.
    * `:validate` — When `true`, performs schema validation and returns
      `{:ok, %WebhookEvent{}}` or `{:error, reason}`. Defaults to `false`.
      Cannot be combined with `:raw`.

  ## Examples

      iex> parse(body, provider: "stripe")
      %WebhookEvent{type: "payment_intent.succeeded", ...}

      iex> parse(body, raw: true)
      %{"type" => "payment_intent.succeeded", "data" => %{...}}

      iex> parse(body, provider: "stripe", validate: true)
      {:ok, %WebhookEvent{...}}

      iex> parse(bad_body, provider: "stripe", validate: true)
      {:error, :missing_event_type}

  """

  def parse(body, opts \\ []) when is_binary(body) and is_list(opts) do
    provider = Keyword.get(opts, :provider, "unknown")

    decoded =
      case Jason.decode(body) do
        {:ok, map} -> map
        {:error, _} -> raise "Invalid JSON payload"
      end

    cond do
      opts[:raw] == true ->
        decoded

      opts[:validate] == true ->
        case normalize(decoded, provider) do
          {:ok, event} -> {:ok, event}
          {:error, reason} -> {:error, reason}
        end

      true ->
        case normalize(decoded, provider) do
          {:ok, event} -> event
          {:error, reason} -> raise "Normalization failed: #{inspect(reason)}"
        end
    end
  end
  
  defp normalize(decoded, provider) when provider in @supported_providers do
    with {:ok, type} <- extract_type(decoded, provider),
         {:ok, resource_id} <- extract_resource_id(decoded, provider) do
      event = %WebhookEvent{
        provider: provider,
        event_type: type,
        resource_id: resource_id,
        payload: decoded,
        received_at: DateTime.utc_now()
      }

      {:ok, event}
    end
  end

  defp normalize(decoded, _unknown_provider) do
    type = Map.get(decoded, "type") || Map.get(decoded, "event")

    if type do
      {:ok,
       %WebhookEvent{
         provider: "unknown",
         event_type: type,
         resource_id: nil,
         payload: decoded,
         received_at: DateTime.utc_now()
       }}
    else
      {:error, :missing_event_type}
    end
  end

  defp extract_type(%{"type" => t}, "stripe") when is_binary(t), do: {:ok, t}
  defp extract_type(_, "stripe"), do: {:error, :missing_event_type}

  defp extract_type(%{"action" => a, "object" => obj}, "github"),
    do: {:ok, "#{obj}.#{a}"}

  defp extract_type(_, "github"), do: {:error, :missing_event_type}

  defp extract_type(%{"MessageSid" => sid}, "twilio"), do: {:ok, "message.#{sid}"}
  defp extract_type(_, "twilio"), do: {:error, :missing_event_type}

  defp extract_resource_id(%{"data" => %{"object" => %{"id" => id}}}, "stripe"),
    do: {:ok, id}

  defp extract_resource_id(_, "stripe"), do: {:ok, nil}
  defp extract_resource_id(decoded, _), do: {:ok, Map.get(decoded, "id")}

  @doc """
  Returns the list of provider names this parser supports with normalization.
  """
  def supported_providers, do: @supported_providers
end
```
