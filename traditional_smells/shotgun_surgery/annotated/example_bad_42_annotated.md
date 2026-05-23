# Smell: Shotgun Surgery

- **Smell Name:** Shotgun Surgery
- **Expected Smell Location:** `MyApp.Shipping.RateCalculator`, `MyApp.Shipping.LabelGenerator`, `MyApp.Shipping.TrackingService`
- **Affected Functions:** `RateCalculator.calculate/3`, `LabelGenerator.generate/2`, `TrackingService.fetch_status/2`
- **Explanation:** Adding a new shipping carrier (e.g., `:dhl`) requires small but mandatory changes in all three modules: a rate calculation clause in `RateCalculator`, a label generation clause in `LabelGenerator`, and a tracking integration in `TrackingService`. Carrier-specific logic is scattered rather than encapsulated.

```elixir
# VALIDATION: SMELL START - Shotgun Surgery
# VALIDATION: This is a smell because onboarding a new carrier (e.g., :dhl) mandates
# VALIDATION: simultaneous changes in RateCalculator.calculate/3, LabelGenerator.generate/2,
# VALIDATION: and TrackingService.fetch_status/2. These three modules must be updated
# VALIDATION: in lockstep for every carrier addition, spreading responsibility widely.

defmodule MyApp.Shipping.RateCalculator do
  @moduledoc """
  Calculates shipping rates for supported carriers based on package weight,
  dimensions, and destination zip code. Rates are retrieved from carrier
  APIs and cached per-session to avoid redundant network calls.
  """

  alias MyApp.Shipping.ZoneResolver
  alias MyApp.Carriers.{FedexClient, UpsClient, CorreiosClient}

  def calculate(:fedex, package, destination_zip) do
    zone = ZoneResolver.resolve(:fedex, destination_zip)

    case FedexClient.rate_quote(package.weight_kg, package.dimensions, zone) do
      {:ok, %{amount: amount, currency: currency}} ->
        {:ok, %{carrier: :fedex, amount: amount, currency: currency, zone: zone}}

      {:error, reason} ->
        {:error, {:fedex_rate_error, reason}}
    end
  end

  def calculate(:ups, package, destination_zip) do
    zone = ZoneResolver.resolve(:ups, destination_zip)

    case UpsClient.get_rate(package.weight_kg, package.dimensions, zone, :ground) do
      {:ok, %{negotiated_rate: amount}} ->
        {:ok, %{carrier: :ups, amount: amount, currency: "USD", zone: zone}}

      {:error, reason} ->
        {:error, {:ups_rate_error, reason}}
    end
  end

  def calculate(:correios, package, destination_zip) do
    case CorreiosClient.calcular_preco("PAC", destination_zip, package.weight_kg) do
      {:ok, %{valor: amount}} ->
        {:ok, %{carrier: :correios, amount: amount, currency: "BRL", zone: nil}}

      {:error, reason} ->
        {:error, {:correios_rate_error, reason}}
    end
  end

  def calculate(unknown_carrier, _package, _zip) do
    {:error, {:unsupported_carrier, unknown_carrier}}
  end
end

defmodule MyApp.Shipping.LabelGenerator do
  @moduledoc """
  Generates printable shipping labels for each supported carrier.
  Labels are returned as base64-encoded PDF blobs along with tracking metadata.
  """

  alias MyApp.Carriers.{FedexClient, UpsClient, CorreiosClient}

  def generate(:fedex, shipment) do
    params = %{
      service_type: "FEDEX_GROUND",
      shipper: shipment.sender,
      recipient: shipment.recipient,
      package: shipment.package,
      account_number: Application.fetch_env!(:my_app, :fedex_account)
    }

    case FedexClient.create_shipment(params) do
      {:ok, %{label_pdf: pdf, tracking_number: tracking_number}} ->
        {:ok, %{carrier: :fedex, label_pdf: pdf, tracking_number: tracking_number}}

      {:error, reason} ->
        {:error, {:fedex_label_error, reason}}
    end
  end

  def generate(:ups, shipment) do
    params = %{
      service_code: "03",
      shipper: shipment.sender,
      ship_to: shipment.recipient,
      package: shipment.package
    }

    case UpsClient.ship(params) do
      {:ok, %{graphicImage: pdf, trackingNumber: tracking_number}} ->
        {:ok, %{carrier: :ups, label_pdf: Base.decode64!(pdf), tracking_number: tracking_number}}

      {:error, reason} ->
        {:error, {:ups_label_error, reason}}
    end
  end

  def generate(:correios, shipment) do
    params = %{
      servico: "PAC",
      remetente: shipment.sender,
      destinatario: shipment.recipient,
      objeto: shipment.package
    }

    case CorreiosClient.postar_objeto(params) do
      {:ok, %{etiqueta: tracking_number, label: pdf}} ->
        {:ok, %{carrier: :correios, label_pdf: pdf, tracking_number: tracking_number}}

      {:error, reason} ->
        {:error, {:correios_label_error, reason}}
    end
  end

  def generate(unknown_carrier, _shipment) do
    {:error, {:unsupported_carrier, unknown_carrier}}
  end
end

defmodule MyApp.Shipping.TrackingService do
  @moduledoc """
  Fetches real-time tracking status for a shipment given its carrier and tracking number.
  Normalizes each carrier's proprietary event vocabulary into a unified status schema.
  """

  alias MyApp.Carriers.{FedexClient, UpsClient, CorreiosClient}

  def fetch_status(:fedex, tracking_number) do
    case FedexClient.track(tracking_number) do
      {:ok, %{events: events, status: raw_status}} ->
        {:ok,
         %{
           carrier: :fedex,
           tracking_number: tracking_number,
           status: normalize_fedex_status(raw_status),
           events: Enum.map(events, &format_fedex_event/1),
           last_updated: DateTime.utc_now()
         }}

      {:error, reason} ->
        {:error, {:fedex_tracking_error, reason}}
    end
  end

  def fetch_status(:ups, tracking_number) do
    case UpsClient.track_shipment(tracking_number) do
      {:ok, %{Activity: activities, Status: raw_status}} ->
        {:ok,
         %{
           carrier: :ups,
           tracking_number: tracking_number,
           status: normalize_ups_status(raw_status),
           events: Enum.map(activities, &format_ups_event/1),
           last_updated: DateTime.utc_now()
         }}

      {:error, reason} ->
        {:error, {:ups_tracking_error, reason}}
    end
  end

  def fetch_status(:correios, tracking_number) do
    case CorreiosClient.rastrear_objeto(tracking_number) do
      {:ok, %{eventos: eventos, situacao: situacao}} ->
        {:ok,
         %{
           carrier: :correios,
           tracking_number: tracking_number,
           status: normalize_correios_status(situacao),
           events: Enum.map(eventos, &format_correios_event/1),
           last_updated: DateTime.utc_now()
         }}

      {:error, reason} ->
        {:error, {:correios_tracking_error, reason}}
    end
  end

  def fetch_status(unknown_carrier, _tracking_number) do
    {:error, {:unsupported_carrier, unknown_carrier}}
  end

  defp normalize_fedex_status("OD"), do: :out_for_delivery
  defp normalize_fedex_status("DL"), do: :delivered
  defp normalize_fedex_status("IT"), do: :in_transit
  defp normalize_fedex_status(_), do: :unknown

  defp normalize_ups_status(%{"Type" => "D"}), do: :delivered
  defp normalize_ups_status(%{"Type" => "I"}), do: :in_transit
  defp normalize_ups_status(_), do: :unknown

  defp normalize_correios_status("Entregue"), do: :delivered
  defp normalize_correios_status("Em trânsito"), do: :in_transit
  defp normalize_correios_status(_), do: :unknown

  defp format_fedex_event(e), do: %{timestamp: e.timestamp, description: e.description, location: e.scanLocation}
  defp format_ups_event(e), do: %{timestamp: e["Date"], description: e["Description"], location: e["Location"]}
  defp format_correios_event(e), do: %{timestamp: e.data, description: e.descricao, location: e.local}
end
# VALIDATION: SMELL END
```
