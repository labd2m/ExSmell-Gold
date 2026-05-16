```elixir
defmodule Logistics.CarrierClient do
  @moduledoc """
  HTTP client for communicating with the third-party carrier API.
  Handles shipment lookups, status polling, and delivery confirmation.
  """

  require Logger

  @base_url "https://api.carrier-partner.io/v2"
  @timeout_ms 8_000

  def track_shipment(tracking_number, opts \\ []) do
    carrier = Keyword.get(opts, :carrier, :default)
    result = fetch_shipment_status(tracking_number, carrier)

    case result do
      {:ok, status} ->
        Logger.info("Shipment #{tracking_number} status: #{inspect(status)}")
        {:ok, status}

      {:error, reason} ->
        Logger.warning("Failed to track #{tracking_number}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def confirm_delivery(tracking_number, carrier) do
    case fetch_shipment_status(tracking_number, carrier) do
      {:ok, %{state: "delivered", proof: proof}} ->
        {:ok, %{confirmed: true, proof_of_delivery: proof}}

      {:ok, %{state: state}} ->
        {:error, {:not_delivered, state}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def list_in_transit(tracking_numbers, carrier) do
    tracking_numbers
    |> Enum.map(&fetch_shipment_status(&1, carrier))
    |> Enum.filter(fn
      {:ok, %{state: "in_transit"}} -> true
      _ -> false
    end)
    |> Enum.map(fn {:ok, s} -> s end)
  end

  defp fetch_shipment_status(tracking_number, carrier) do
    url = "#{@base_url}/shipments/#{tracking_number}"
    headers = build_headers(carrier)

    case http_get(url, headers, recv_timeout: @timeout_ms) do
      {:ok, %{status: 200, body: body}} ->
        case body do
          %{"status" => "in_transit", "eta" => eta, "location" => loc} ->
            {:ok, %{state: "in_transit", eta: eta, current_location: loc, proof: nil}}

          %{"status" => "delivered", "delivered_at" => ts, "proof_of_delivery" => proof} ->
            {:ok, %{state: "delivered", delivered_at: ts, proof: proof, eta: nil}}

          %{"status" => "delivered"} ->
            {:ok, %{state: "delivered", delivered_at: nil, proof: nil, eta: nil}}

          %{"status" => "out_for_delivery", "eta" => eta} ->
            {:ok, %{state: "out_for_delivery", eta: eta, current_location: nil, proof: nil}}

          %{"status" => "exception", "reason" => reason, "resolution" => resolution} ->
            {:ok, %{state: "exception", reason: reason, resolution: resolution, proof: nil}}

          %{"status" => "exception", "reason" => reason} ->
            {:ok, %{state: "exception", reason: reason, resolution: nil, proof: nil}}

          %{"status" => "pending"} ->
            {:ok, %{state: "pending", eta: nil, current_location: nil, proof: nil}}

          %{"status" => unknown} ->
            {:error, {:unknown_status, unknown}}

          _ ->
            {:error, :malformed_body}
        end

      {:ok, %{status: 202, body: %{"message" => msg}}} ->
        {:ok, %{state: "processing", message: msg, proof: nil, eta: nil}}

      {:ok, %{status: 404, body: %{"error" => "not_found"}}} ->
        {:error, :shipment_not_found}

      {:ok, %{status: 404}} ->
        {:error, :shipment_not_found}

      {:ok, %{status: 401}} ->
        {:error, :unauthorized}

      {:ok, %{status: 403, body: %{"error" => reason}}} ->
        {:error, {:forbidden, reason}}

      {:ok, %{status: 403}} ->
        {:error, :forbidden}

      {:ok, %{status: 429, body: %{"retry_after" => seconds}}} ->
        {:error, {:rate_limited, String.to_integer(seconds)}}

      {:ok, %{status: 429}} ->
        {:error, {:rate_limited, 60}}

      {:ok, %{status: 500, body: %{"trace_id" => trace_id}}} ->
        Logger.error("Carrier 500 error, trace_id=#{trace_id}")
        {:error, {:server_error, trace_id}}

      {:ok, %{status: 500}} ->
        {:error, :server_error}

      {:ok, %{status: 503}} ->
        {:error, :service_unavailable}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("Unexpected carrier response status=#{status} body=#{inspect(body)}")
        {:error, {:unexpected_response, status}}

      {:error, :timeout} ->
        {:error, :timeout}

      {:error, :econnrefused} ->
        {:error, :carrier_unreachable}

      {:error, reason} ->
        {:error, {:transport_error, reason}}
    end
  end

  defp build_headers(carrier) do
    api_key = System.get_env("CARRIER_API_KEY_#{String.upcase(to_string(carrier))}")
    [{"Authorization", "Bearer #{api_key}"}, {"Accept", "application/json"}]
  end

  defp http_get(url, headers, opts) do
    # Simulated HTTP call — would delegate to Tesla or HTTPoison in production
    _ = {url, headers, opts}
    {:error, :not_implemented}
  end
end
```
