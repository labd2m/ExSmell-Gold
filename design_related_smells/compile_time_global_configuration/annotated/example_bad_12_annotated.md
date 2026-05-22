# Annotated Bad Example 12

## Metadata

- **Smell name:** Compile-time global configuration
- **Expected smell location:** Module attribute `@carrier_api_base` defined at the top of `Logistics.ShipmentTracker`
- **Affected function(s):** `track_shipment/1`, `get_delivery_estimate/2`, `bulk_track/1`
- **Short explanation:** `Application.fetch_env!/2` is called inside the module body to populate the `@carrier_api_base` attribute. Because module attributes are set at compile-time and the Application Environment is not yet available at that stage, this can cause a compilation warning or `ArgumentError`.

---

```elixir
defmodule Logistics.ShipmentTracker do
  @moduledoc """
  Queries an external carrier API to retrieve real-time tracking information
  and estimated delivery windows for outbound shipments. Supports both single
  and bulk (batched) tracking requests.
  """

  require Logger

  # VALIDATION: SMELL START - Compile-time global configuration
  # VALIDATION: This is a smell because Application.fetch_env!/2 is executed in the
  # VALIDATION: module body, assigning the carrier API base URL to a module attribute.
  # VALIDATION: Module attributes are resolved during compilation, not at runtime.
  # VALIDATION: If the :logistics application has not been loaded at compile-time,
  # VALIDATION: Elixir will emit a warning or raise ArgumentError.
  @carrier_api_base Application.fetch_env!(:logistics, :carrier_api_base)
  # VALIDATION: SMELL END

  @carrier_api_key Application.get_env(:logistics, :carrier_api_key, "dev_key")
  @http_timeout_ms 12_000
  @bulk_batch_size 25

  @type tracking_number :: String.t()

  @type tracking_event :: %{
          timestamp: DateTime.t(),
          location: String.t(),
          description: String.t(),
          status: String.t()
        }

  @type tracking_result ::
          {:ok, %{tracking_number: tracking_number(), events: [tracking_event()], status: String.t()}}
          | {:error, :not_found | :api_error | :timeout}

  @doc """
  Fetches the full event history for a single tracking number.

  ## Parameters
    - `tracking_number` - The carrier-issued tracking reference (e.g. `"1Z999AA10123456784"`).
  """
  @spec track_shipment(tracking_number()) :: tracking_result()
  def track_shipment(tracking_number) when is_binary(tracking_number) do
    Logger.info("Tracking shipment tracking_number=#{tracking_number}")
    url = "#{@carrier_api_base}/track/#{URI.encode(tracking_number)}"

    case get(url) do
      {:ok, %{"tracking_number" => tn, "events" => raw_events, "status" => status}} ->
        events = Enum.map(raw_events, &parse_event/1)
        {:ok, %{tracking_number: tn, events: events, status: status}}

      {:error, :not_found} ->
        Logger.warning("Tracking number not found tracking_number=#{tracking_number}")
        {:error, :not_found}

      {:error, reason} ->
        Logger.error("Tracking API error tracking_number=#{tracking_number} reason=#{inspect(reason)}")
        {:error, :api_error}
    end
  end

  @doc """
  Returns the estimated delivery window for a shipment, taking into account
  the destination zip code for local service level adjustments.

  ## Parameters
    - `tracking_number` - The carrier tracking reference.
    - `destination_zip` - Destination postal code to refine the estimate.
  """
  @spec get_delivery_estimate(tracking_number(), String.t()) ::
          {:ok, %{earliest: Date.t(), latest: Date.t()}} | {:error, term()}
  def get_delivery_estimate(tracking_number, destination_zip) do
    url = "#{@carrier_api_base}/estimate"
    params = %{tracking_number: tracking_number, zip: destination_zip}

    case get(url, params) do
      {:ok, %{"earliest_delivery" => earliest, "latest_delivery" => latest}} ->
        {:ok, %{earliest: Date.from_iso8601!(earliest), latest: Date.from_iso8601!(latest)}}

      {:error, reason} ->
        Logger.error("Delivery estimate failed tracking_number=#{tracking_number} reason=#{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Submits up to #{@bulk_batch_size * 10} tracking numbers in parallel batches
  and returns a map of tracking number to result.

  ## Parameters
    - `tracking_numbers` - A list of carrier tracking references.
  """
  @spec bulk_track([tracking_number()]) :: %{tracking_number() => tracking_result()}
  def bulk_track(tracking_numbers) when is_list(tracking_numbers) do
    tracking_numbers
    |> Enum.chunk_every(@bulk_batch_size)
    |> Task.async_stream(fn batch ->
      Enum.map(batch, fn tn -> {tn, track_shipment(tn)} end)
    end, max_concurrency: 4, timeout: @http_timeout_ms * 3)
    |> Enum.flat_map(fn {:ok, results} -> results end)
    |> Map.new()
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp get(url, query_params \\ %{}) do
    full_url = if map_size(query_params) > 0, do: url <> "?" <> URI.encode_query(query_params), else: url

    headers = [
      {"X-Api-Key", @carrier_api_key},
      {"Accept", "application/json"}
    ]

    case HTTPoison.get(full_url, headers, recv_timeout: @http_timeout_ms) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        {:ok, Jason.decode!(body)}

      {:ok, %HTTPoison.Response{status_code: 404}} ->
        {:error, :not_found}

      {:ok, %HTTPoison.Response{status_code: status}} ->
        {:error, {:http_error, status}}

      {:error, %HTTPoison.Error{reason: :timeout}} ->
        {:error, :timeout}

      {:error, %HTTPoison.Error{reason: reason}} ->
        {:error, reason}
    end
  end

  defp parse_event(%{"timestamp" => ts, "location" => loc, "description" => desc, "status" => st}) do
    %{
      timestamp: DateTime.from_iso8601!(ts),
      location: loc,
      description: desc,
      status: st
    }
  end
end
```
