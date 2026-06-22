```elixir
defmodule Platform.WebhookSignaturePlug do
  @moduledoc """
  Verifies inbound webhook signatures before the request body reaches any
  controller. The raw request body must be read and stored before this plug
  runs. Signature verification is delegated to `Integration.WebhookVerifier`
  so provider-specific logic remains encapsulated. Requests with invalid
  signatures are rejected with 401 before any business logic executes.
  """

  @behaviour Plug

  import Plug.Conn

  @provider_header "x-webhook-provider"

  @impl Plug
  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @impl Plug
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(%Plug.Conn{} = conn, _opts) do
    with {:ok, provider} <- resolve_provider(conn),
         {:ok, raw_body} <- get_raw_body(conn),
         {:ok, rejection_reason} <- verify_signature(provider, header_map(conn), raw_body) do
      assign(conn, :webhook_provider, provider)
    else
      {:error, rejection_reason} -> reject(conn, rejection_reason)
    end
  end

  @spec resolve_provider(Plug.Conn.t()) :: {:ok, atom()} | {:error, String.t()}
  defp resolve_provider(conn) do
    case get_req_header(conn, @provider_header) do
      [provider | _] -> validate_provider(provider)
      [] -> {:error, "unknown_provider"}
    end
  end

  @spec validate_provider(String.t()) :: {:ok, atom()} | {:error, String.t()}
  defp validate_provider(provider) when provider in ["stripe", "github", "shopify", "twilio"] do
    {:ok, String.to_existing_atom(provider)}
  end

  defp validate_provider(_provider), do: {:error, "unknown_provider"}

  @spec get_raw_body(Plug.Conn.t()) :: {:ok, binary()} | {:error, String.t()}
  defp get_raw_body(conn) do
    case conn.assigns[:raw_body] do
      body when is_binary(body) ->
        {:ok, body}

      nil ->
        case Plug.Conn.read_body(conn) do
          {:ok, body, _conn} -> {:ok, body}
          _ -> {:error, "verification_failed"}
        end
    end
  end

  @spec verify_signature(atom(), map(), binary()) :: {:ok, atom()} | {:error, String.t()}
  defp verify_signature(provider, headers, raw_body) do
    case Integration.WebhookVerifier.verify(provider, headers, raw_body) do
      :ok -> {:ok, provider}
      {:error, :missing_header} -> {:error, "missing_signature"}
      {:error, :invalid_signature} -> {:error, "invalid_signature"}
      {:error, :expired} -> {:error, "signature_expired"}
      {:error, _} -> {:error, "verification_failed"}
    end
  end

  @spec header_map(Plug.Conn.t()) :: map()
  defp header_map(conn) do
    Map.new(conn.req_headers, fn {k, v} -> {k, v} end)
  end

  @spec reject(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  defp reject(conn, reason) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: "webhook_verification_failed", reason: reason}))
    |> halt()
  end
end
```
