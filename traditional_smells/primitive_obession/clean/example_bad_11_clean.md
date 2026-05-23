```elixir
defmodule Logistics.ParcelClassifier do
  @moduledoc """
  Classifies parcels by size and calculates volumetric weight for
  carrier billing. Supports standard and oversized thresholds for
  multiple carrier integrations.
  """

  require Logger

  @dim_weight_divisor_air 5_000.0
  @dim_weight_divisor_ground 6_000.0
  @max_girth_cm 419.0

  # Carrier size limits (length, width, height) in cm
  @carrier_limits %{
    "fedex" => {274.0, 122.0, 122.0},
    "ups" => {270.0, 120.0, 120.0},
    "dhl" => {300.0, 200.0, 160.0},
    "usps" => {108.0, 108.0, 108.0}
  }

  @spec volumetric_weight(float(), float(), float(), String.t()) ::
          {:ok, float()} | {:error, String.t()}
  def volumetric_weight(length_cm, width_cm, height_cm, service_type)
      when is_float(length_cm) and is_float(width_cm) and is_float(height_cm) do
    with :ok <- validate_dimensions(length_cm, width_cm, height_cm) do
      divisor =
        case service_type do
          "air" -> @dim_weight_divisor_air
          _ -> @dim_weight_divisor_ground
        end

      vol_weight = Float.round(length_cm * width_cm * height_cm / divisor, 3)
      {:ok, vol_weight}
    end
  end

  @spec fits_in_box?(float(), float(), float(), float(), float(), float()) :: boolean()
  def fits_in_box?(
        item_length,
        item_width,
        item_height,
        box_length,
        box_width,
        box_height
      ) do
    sorted_item = Enum.sort([item_length, item_width, item_height], :desc)
    sorted_box = Enum.sort([box_length, box_width, box_height], :desc)

    Enum.zip(sorted_item, sorted_box)
    |> Enum.all?(fn {item_dim, box_dim} -> item_dim <= box_dim end)
  end

  @spec classify_parcel(float(), float(), float()) ::
          {:ok, String.t()} | {:error, String.t()}
  def classify_parcel(length_cm, width_cm, height_cm) do
    with :ok <- validate_dimensions(length_cm, width_cm, height_cm) do
      longest = Enum.max([length_cm, width_cm, height_cm])
      girth = 2 * (width_cm + height_cm)
      combined = longest + girth

      label =
        cond do
          combined > @max_girth_cm ->
            "unacceptable"

          longest > 150.0 or combined > 270.0 ->
            "oversized"

          length_cm * width_cm * height_cm > 125_000.0 ->
            "large"

          true ->
            "standard"
        end

      Logger.debug(
        "Parcel #{length_cm}×#{width_cm}×#{height_cm} cm classified as #{label}"
      )

      {:ok, label}
    end
  end

  @spec carrier_accepts?(String.t(), float(), float(), float()) :: boolean()
  def carrier_accepts?(carrier, length_cm, width_cm, height_cm) do
    case Map.get(@carrier_limits, carrier) do
      nil ->
        false

      {max_l, max_w, max_h} ->
        fits_in_box?(length_cm, width_cm, height_cm, max_l, max_w, max_h)
    end
  end

  @spec dimensional_charge(float(), float(), float(), float()) ::
          {:ok, float()} | {:error, String.t()}
  def dimensional_charge(length_cm, width_cm, height_cm, rate_per_kg) do
    with {:ok, vol_weight_kg} <- volumetric_weight(length_cm, width_cm, height_cm, "ground") do
      charge = Float.round(vol_weight_kg * rate_per_kg, 2)
      {:ok, charge}
    end
  end

  defp validate_dimensions(l, w, h) do
    cond do
      l <= 0.0 or w <= 0.0 or h <= 0.0 ->
        {:error, "All dimensions must be positive, got #{l}×#{w}×#{h} cm"}

      l > 500.0 or w > 500.0 or h > 500.0 ->
        {:error, "Dimension exceeds absolute maximum of 500 cm"}

      true ->
        :ok
    end
  end
end
```
