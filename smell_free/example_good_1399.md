**File:** `example_good_1399.md`

```elixir
defmodule WebhookIngress.SignatureError do
  @moduledoc "Raised when an inbound webhook signature cannot be verified."

  defexception [:provider, :reason]

  @impl Exception
  def exception({provider, reason}) do
    %__MODULE__{provider: provider, reason: reason}
  end

  @impl Exception
  def message(%__MODULE__{provider: p, reason: r}) do
    "Webhook signature verification failed for #{p}: #{inspect(r)}"
  end
end

defmodule WebhookIngress.Event do
  @moduledoc "Represents a verified, parsed inbound webhook event."

  @enforce_keys [:id, :provider, :event_type, :payload, :received_at]
  defstruct [:id, :provider, :event_type, :payload, :received_at, :raw_headers]

  @type t :: %__MODULE__{
          id: String.t(),
          provider: String.t(),
          event_type: String.t(),
          payload: map(),
          received_at: DateTime.t(),
          raw_headers: map()
        }
end

defmodule WebhookIngress.Provider do
  @moduledoc "Behaviour for webhook provider-specific verification and parsing."

  alias WebhookIngress.Event

  @doc "Verifies the request signature. Returns :ok or {:error, reason}."
  @callback verify_signature(binary(), map(), String.t()) :: :ok | {:error, term()}

  @doc "Extracts the event type string from headers or body."
  @callback extract_event_type(map(), map()) :: {:ok, String.t()} | {:error, term()}

  @doc "Returns the provider's string identifier."
  @callback provider_name() :: String.t()
end

defmodule WebhookIngress.Providers.Stripe do
  @moduledoc "Webhook provider implementation for Stripe signed events."

  @behaviour WebhookIngress.Provider

  @impl WebhookIngress.Provider
  def provider_name, do: "stripe"

  @impl WebhookIngress.Provider
  def verify_signature(raw_body, headers, secret) do
    with {:ok, sig_header} <- fetch_header(headers, "stripe-signature"),
         {:ok, timestamp, signatures} <- parse_stripe_signature(sig_header),
         :ok <- check_timestamp_tolerance(timestamp),
         :ok <- verify_hmac(raw_body, timestamp, signatures, secret) do
      :ok
    end
  end

  @impl WebhookIngress.Provider
  def extract_event_type(_headers, body) do
    case Map.get(body, "type") do
      type when is_binary(type) and type != "" -> {:ok, type}
      _ -> {:error, :missing_event_type}
    end
  end

  defp fetch_header(headers, key) do
    case Map.get(headers, key) do
      nil -> {:error, {:missing_header, key}}
      val -> {:ok, val}
    end
  end

  defp parse_stripe_signature(sig_header) do
    parts =
      sig_header
      |> String.split(",")
      |> Enum.map(&String.split(&1, "=", parts: 2))
      |> Enum.filter(&match?([_, _], &1))
      |> Map.new(fn [k, v] -> {k, v} end)

    with {:ok, ts_str} <- Map.fetch(parts, "t"),
         {ts, ""} <- Integer.parse(ts_str) do
      sigs = parts |> Enum.filter(fn {k, _} -> k == "v1" end) |> Enum.map(fn {_, v} -> v end)
      {:ok, ts, sigs}
    else
      _ -> {:error, :malformed_signature_header}
    end
  end

  defp check_timestamp_tolerance(timestamp) do
    now = System.system_time(:second)
    if abs(now - timestamp) <= 300, do: :ok, else: {:error, :timestamp_too_old}
  end

  defp verify_hmac(raw_body, timestamp, signatures, secret) do
    payload = "#{timestamp}.#{raw_body}"
    expected = :crypto.mac(:hmac, :sha256, secret, payload) |> Base.encode16(case: :lower)

    if Enum.any?(signatures, &:crypto.hash_equals(&1, expected)) do
      :ok
    else
      {:error, :signature_mismatch}
    end
  end
end

defmodule WebhookIngress do
  @moduledoc """
  Verifies and parses inbound webhook requests from configured providers.
  """

  alias WebhookIngress.{Event, Provider, SignatureError}

  @providers %{
    "stripe" => WebhookIngress.Providers.Stripe
  }

  @spec ingest(String.t(), binary(), map(), String.t()) ::
          {:ok, Event.t()} | {:error, term()}
  def ingest(provider_name, raw_body, headers, secret) do
    with {:ok, provider} <- fetch_provider(provider_name),
         :ok <- provider.verify_signature(raw_body, headers, secret),
         {:ok, body} <- Jason.decode(raw_body),
         {:ok, event_type} <- provider.extract_event_type(headers, body) do
      {:ok, %Event{
        id: Map.get(body, "id", generate_id()),
        provider: provider_name,
        event_type: event_type,
        payload: body,
        received_at: DateTime.utc_now(),
        raw_headers: headers
      }}
    end
  end

  defp fetch_provider(name) do
    case Map.fetch(@providers, name) do
      {:ok, mod} -> {:ok, mod}
      :error -> {:error, {:unknown_provider, name}}
    end
  end

  defp generate_id do
    :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
  end
end
```
