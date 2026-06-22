```elixir
defmodule Shipping.Carrier do
  @moduledoc """
  Behaviour that all shipping carrier adapters must implement.
  Each adapter translates between the internal shipment model and the
  carrier's external API, returning normalized result tuples.
  """

  @type shipment :: %{
          sender: map(),
          recipient: map(),
          weight_grams: pos_integer(),
          dimensions_mm: %{length: pos_integer(), width: pos_integer(), height: pos_integer()},
          service_level: atom()
        }

  @type rate_quote :: %{
          carrier: atom(),
          service_level: atom(),
          price_cents: non_neg_integer(),
          estimated_days: pos_integer(),
          currency: String.t()
        }

  @type tracking_event :: %{
          status: atom(),
          location: String.t() | nil,
          description: String.t(),
          occurred_at: DateTime.t()
        }

  @callback quote_rates(shipment()) :: {:ok, list(rate_quote())} | {:error, atom()}
  @callback create_label(shipment(), rate_quote()) ::
              {:ok, %{tracking_number: String.t(), label_pdf: binary()}} | {:error, atom()}
  @callback track(String.t()) :: {:ok, list(tracking_event())} | {:error, atom()}
  @callback void_label(String.t()) :: :ok | {:error, atom()}
end

defmodule Shipping.Carriers.FedEx do
  @moduledoc """
  FedEx carrier adapter. Translates internal shipment structs to the
  FedEx REST API format and normalizes responses back to the common schema.
  """

  @behaviour Shipping.Carrier

  @base_url "https://apis.fedex.com"

  @impl Shipping.Carrier
  def quote_rates(shipment) when is_map(shipment) do
    payload = build_rate_request(shipment)

    with {:ok, response} <- post("/rate/v1/rates/quotes", payload),
         {:ok, quotes} <- parse_rate_response(response) do
      {:ok, quotes}
    end
  end

  @impl Shipping.Carrier
  def create_label(shipment, rate_quote) when is_map(shipment) and is_map(rate_quote) do
    payload = build_label_request(shipment, rate_quote)

    with {:ok, response} <- post("/ship/v1/shipments", payload),
         {:ok, label_data} <- parse_label_response(response) do
      {:ok, label_data}
    end
  end

  @impl Shipping.Carrier
  def track(tracking_number) when is_binary(tracking_number) do
    with {:ok, response} <- post("/track/v1/trackingnumbers", %{trackingInfo: [%{trackingNumberInfo: %{trackingNumber: tracking_number}}]}),
         {:ok, events} <- parse_tracking_response(response) do
      {:ok, events}
    end
  end

  @impl Shipping.Carrier
  def void_label(tracking_number) when is_binary(tracking_number) do
    payload = %{accountNumber: %{value: api_config(:account_number)}, trackingNumber: tracking_number}

    case put("/ship/v1/shipments/cancel", payload) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  defp build_rate_request(%{sender: sender, recipient: recipient, weight_grams: weight}) do
    %{
      accountNumber: %{value: api_config(:account_number)},
      requestedShipment: %{
        shipper: %{address: encode_address(sender)},
        recipient: %{address: encode_address(recipient)},
        requestedPackageLineItems: [%{weight: %{units: "G", value: weight}}]
      }
    }
  end

  defp build_label_request(shipment, %{service_level: service}) do
    %{
      requestedShipment: %{
        shipper: %{address: encode_address(shipment.sender)},
        recipients: [%{address: encode_address(shipment.recipient)}],
        serviceType: normalize_service_code(service),
        requestedPackageLineItems: [%{weight: %{units: "G", value: shipment.weight_grams}}],
        labelSpecification: %{imageType: "PDF", labelStockType: "PAPER_4X6"}
      }
    }
  end

  defp parse_rate_response(%{"output" => %{"rateReplyDetails" => details}}) do
    quotes =
      Enum.flat_map(details, fn detail ->
        Enum.map(detail["ratedShipmentDetails"] || [], fn rated ->
          %{
            carrier: :fedex,
            service_level: String.to_existing_atom(detail["serviceType"]),
            price_cents: round(rated["totalNetCharge"] * 100),
            estimated_days: detail["operationalDetail"]["transitDays"] || 0,
            currency: rated["currency"] || "USD"
          }
        end)
      end)

    {:ok, quotes}
  rescue
    _ -> {:error, :unparseable_rate_response}
  end

  defp parse_rate_response(_), do: {:error, :unexpected_rate_response}

  defp parse_label_response(%{"output" => %{"transactionShipments" => [shipment | _]}}) do
    tracking = get_in(shipment, ["masterTrackingNumber"])
    label_pdf = get_in(shipment, ["pieceResponses", Access.at(0), "packageDocuments", Access.at(0), "encodedLabel"])

    if is_binary(tracking) and is_binary(label_pdf) do
      {:ok, %{tracking_number: tracking, label_pdf: Base.decode64!(label_pdf)}}
    else
      {:error, :missing_label_data}
    end
  rescue
    _ -> {:error, :unparseable_label_response}
  end

  defp parse_label_response(_), do: {:error, :unexpected_label_response}

  defp parse_tracking_response(%{"output" => %{"completeTrackResults" => results}}) do
    events =
      results
      |> Enum.flat_map(fn r -> get_in(r, ["trackResults", Access.all(), "scanEvents"]) || [] end)
      |> Enum.map(&normalize_tracking_event/1)
      |> Enum.sort_by(& &1.occurred_at, {:desc, DateTime})

    {:ok, events}
  rescue
    _ -> {:error, :unparseable_tracking_response}
  end

  defp parse_tracking_response(_), do: {:error, :unexpected_tracking_response}

  defp normalize_tracking_event(event) do
    %{
      status: event["eventType"] |> String.downcase() |> String.to_existing_atom(),
      location: event["scanLocation"]["city"],
      description: event["eventDescription"],
      occurred_at: event["date"] |> DateTime.from_iso8601() |> elem(1)
    }
  rescue
    _ -> %{status: :unknown, location: nil, description: "Unknown event", occurred_at: DateTime.utc_now()}
  end

  defp encode_address(%{city: city, country_code: country, postal_code: postal}) do
    %{city: city, countryCode: country, postalCode: postal}
  end

  defp normalize_service_code(:ground), do: "FEDEX_GROUND"
  defp normalize_service_code(:express), do: "FEDEX_EXPRESS_SAVER"
  defp normalize_service_code(:overnight), do: "STANDARD_OVERNIGHT"
  defp normalize_service_code(other), do: other |> to_string() |> String.upcase()

  defp post(path, body) do
    url = @base_url <> path
    headers = [{"Authorization", "Bearer #{fetch_token()}"}, {"Content-Type", "application/json"}]

    case :hackney.post(url, headers, Jason.encode!(body), []) do
      {:ok, status, _, ref} when status in 200..299 ->
        {:ok, body_ref} = :hackney.body(ref)
        Jason.decode(body_ref)

      {:ok, status, _, _ref} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, {:transport_error, reason}}
    end
  end

  defp put(path, body) do
    url = @base_url <> path
    headers = [{"Authorization", "Bearer #{fetch_token()}"}, {"Content-Type", "application/json"}]

    case :hackney.put(url, headers, Jason.encode!(body), []) do
      {:ok, status, _, _} when status in 200..299 -> {:ok, :success}
      {:ok, status, _, _} -> {:error, {:http_error, status}}
      {:error, reason} -> {:error, {:transport_error, reason}}
    end
  end

  defp fetch_token, do: api_config(:api_token)
  defp api_config(key), do: Application.fetch_env!(:shipping, [:fedex, key])
end
```
