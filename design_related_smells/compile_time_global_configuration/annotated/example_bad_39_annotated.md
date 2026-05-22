# Annotated Example — Compile-time Global Configuration

## Metadata

- **Smell:** Compile-time global configuration
- **Expected Smell Location:** Module attribute `@api_base_url` defined via `Application.fetch_env!/2` at the top of the module body
- **Affected Function(s):** `get_user/1`, `list_orders/2`, `create_return/2`
- **Explanation:** `Application.fetch_env!/2` is called at compile-time to capture the partner API base URL and assign it to `@api_base_url`. The `:integrations` application is not loaded during compilation, so this triggers a warning or `ArgumentError`. The URL is frozen in the beam, preventing the client from targeting different environments (sandbox vs production) at runtime.

---

```elixir
defmodule Integrations.PartnerApiClient do
  @moduledoc """
  HTTP client for the partner order-management API.
  Exposes user lookup, order listing, and return creation.
  All requests are authenticated via HMAC-signed headers.
  """

  require Logger

  # VALIDATION: SMELL START - Compile-time global configuration
  # VALIDATION: This is a smell because Application.fetch_env!/2 is evaluated
  # VALIDATION: at module-compilation time. When Mix compiles this file,
  # VALIDATION: :integrations has not been started, so Elixir raises:
  # VALIDATION:   ** (ArgumentError) could not fetch application environment
  # VALIDATION:     :partner_api_base_url for application :integrations
  # VALIDATION: The resolved URL string is also baked into the .beam,
  # VALIDATION: preventing sandbox/production switching at runtime.
  @api_base_url Application.fetch_env!(:integrations, :partner_api_base_url)
  # VALIDATION: SMELL END

  @request_timeout_ms 20_000
  @max_page_size 100
  @default_page_size 25

  @type user_id :: String.t()
  @type order_id :: String.t()

  @type user :: %{
          id: user_id(),
          email: String.t(),
          name: String.t(),
          created_at: String.t()
        }

  @type order :: %{
          id: order_id(),
          status: String.t(),
          total_cents: integer(),
          currency: String.t(),
          created_at: String.t()
        }

  @spec get_user(user_id()) :: {:ok, user()} | {:error, :not_found | :api_error}
  def get_user(user_id) when is_binary(user_id) do
    case get("/users/#{URI.encode(user_id)}") do
      {:ok, %{"id" => _, "email" => _} = body} ->
        {:ok, parse_user(body)}

      {:error, 404} ->
        {:error, :not_found}

      {:error, _} ->
        {:error, :api_error}
    end
  end

  @spec list_orders(user_id(), keyword()) ::
          {:ok, %{orders: [order()], total: integer(), page: integer()}}
          | {:error, :not_found | :api_error}
  def list_orders(user_id, opts \\ []) when is_binary(user_id) do
    page = Keyword.get(opts, :page, 1)
    per_page = min(Keyword.get(opts, :per_page, @default_page_size), @max_page_size)
    status = Keyword.get(opts, :status)

    query_params =
      %{page: page, per_page: per_page}
      |> then(&if(status, do: Map.put(&1, :status, status), else: &1))
      |> URI.encode_query()

    case get("/users/#{URI.encode(user_id)}/orders?#{query_params}") do
      {:ok, %{"orders" => orders, "total" => total}} ->
        {:ok, %{orders: Enum.map(orders, &parse_order/1), total: total, page: page}}

      {:error, 404} ->
        {:error, :not_found}

      {:error, _} ->
        {:error, :api_error}
    end
  end

  @spec create_return(order_id(), %{reason: String.t(), line_items: [map()]}) ::
          {:ok, map()} | {:error, :invalid_request | :api_error}
  def create_return(order_id, params) when is_binary(order_id) do
    case post("/orders/#{URI.encode(order_id)}/returns", params) do
      {:ok, body} ->
        Logger.info("Return created", order_id: order_id, return_id: body["id"])
        {:ok, body}

      {:error, 422} ->
        {:error, :invalid_request}

      {:error, _} ->
        {:error, :api_error}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp get(path) do
    url = @api_base_url <> path
    headers = build_headers("GET", path, "")

    case http_client().get(url, headers, timeout: @request_timeout_ms) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, Jason.decode!(body)}

      {:ok, %{status: status}} ->
        Logger.warning("Partner API returned non-2xx", status: status, path: path)
        {:error, status}

      {:error, reason} ->
        Logger.error("Partner API request error", path: path, reason: inspect(reason))
        {:error, :network_error}
    end
  end

  defp post(path, body_map) do
    url = @api_base_url <> path
    body = Jason.encode!(body_map)
    headers = build_headers("POST", path, body)

    case http_client().post(url, body, headers, timeout: @request_timeout_ms) do
      {:ok, %{status: status, body: resp_body}} when status in 200..299 ->
        {:ok, Jason.decode!(resp_body)}

      {:ok, %{status: status}} ->
        {:error, status}

      {:error, reason} ->
        Logger.error("Partner API post error", path: path, reason: inspect(reason))
        {:error, :network_error}
    end
  end

  defp build_headers(method, path, body) do
    timestamp = System.system_time(:second) |> to_string()
    api_key = Application.fetch_env!(:integrations, :partner_api_key)
    api_secret = Application.fetch_env!(:integrations, :partner_api_secret)
    sig = hmac_signature(api_secret, method, path, timestamp, body)

    [
      {"X-API-Key", api_key},
      {"X-Timestamp", timestamp},
      {"X-Signature", sig},
      {"Content-Type", "application/json"}
    ]
  end

  defp hmac_signature(secret, method, path, timestamp, body) do
    message = "#{method}\n#{path}\n#{timestamp}\n#{body}"
    :crypto.mac(:hmac, :sha256, secret, message) |> Base.encode16(case: :lower)
  end

  defp parse_user(raw),
    do: Map.take(raw, ["id", "email", "name", "created_at"]) |> Map.new(fn {k, v} -> {String.to_atom(k), v} end)

  defp parse_order(raw),
    do: Map.take(raw, ["id", "status", "total_cents", "currency", "created_at"]) |> Map.new(fn {k, v} -> {String.to_atom(k), v} end)

  defp http_client, do: Application.get_env(:integrations, :http_client, Integrations.HttpClient)
end
```
