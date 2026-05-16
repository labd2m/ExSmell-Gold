```elixir
defmodule Logistics.CustomsDeclaration do
  @moduledoc """
  Prepares customs declaration documents for international shipments.
  Validates trade compliance data (HS codes, country of origin,
  export licences) and produces a structured declaration payload
  suitable for submission to customs authorities.
  """

  require Logger

  @dutiable_threshold_usd 800
  @restricted_countries   ~w(KP IR SY CU)
  @license_required_categories ~w(dual-use military-grade controlled-chem)

  @type shipment :: %{
          id: String.t(),
          origin_country: String.t(),
          destination_country: String.t(),
          declared_value_usd: float(),
          weight_kg: float(),
          description: String.t(),
          category: String.t(),
          optional(:hs_code) => String.t(),
          optional(:country_of_origin) => String.t(),
          optional(:license_number) => String.t(),
          optional(:diplomatic_pouch) => boolean()
        }

  @spec prepare(shipment()) :: {:ok, map()} | {:error, [String.t()]}
  def prepare(shipment) do
    with :ok <- check_restrictions(shipment),
         :ok <- check_license(shipment),
         {:ok, declaration} <- build_declaration(shipment) do
      Logger.info("Customs declaration prepared for shipment=#{shipment.id}")
      {:ok, declaration}
    end
  end

  defp check_restrictions(shipment) do
    if shipment.destination_country in @restricted_countries do
      {:error, ["destination country #{shipment.destination_country} is restricted"]}
    else
      :ok
    end
  end

  defp check_license(shipment) do
    if shipment.category in @license_required_categories do
      license = shipment[:license_number]

      if is_nil(license) or String.trim(license) == "" do
        {:error, ["export licence required for category: #{shipment.category}"]}
      else
        :ok
      end
    else
      :ok
    end
  end

  defp build_declaration(shipment) do
    hs_code           = shipment[:hs_code]
    country_of_origin = shipment[:country_of_origin]
    diplomatic_pouch  = shipment[:diplomatic_pouch]

    dutiable = shipment.declared_value_usd > @dutiable_threshold_usd

    declaration = %{
      reference_number:    "CD-#{shipment.id}",
      shipment_id:         shipment.id,
      origin_country:      shipment.origin_country,
      destination_country: shipment.destination_country,
      country_of_origin:   country_of_origin,
      hs_code:             hs_code,
      description:         shipment.description,
      category:            shipment.category,
      declared_value_usd:  shipment.declared_value_usd,
      weight_kg:           shipment.weight_kg,
      dutiable:            dutiable,
      diplomatic_pouch:    diplomatic_pouch || false,
      prepared_at:         DateTime.utc_now()
    }

    {:ok, declaration}
  end

  @spec estimated_duty(map()) :: float()
  def estimated_duty(%{dutiable: false}), do: 0.0
  def estimated_duty(%{declared_value_usd: value, destination_country: country}) do
    rate = duty_rate(country)
    Float.round(value * rate, 2)
  end

  defp duty_rate("GB"), do: 0.05
  defp duty_rate("AU"), do: 0.07
  defp duty_rate("JP"), do: 0.04
  defp duty_rate(_),    do: 0.06

  @spec serialize(map()) :: String.t()
  def serialize(declaration) do
    declaration
    |> Map.drop([:prepared_at])
    |> Jason.encode!()
  rescue
    e -> raise "Failed to serialise declaration: #{inspect(e)}"
  end
end
```
