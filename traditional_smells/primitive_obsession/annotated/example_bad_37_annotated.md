# Annotated Example — Primitive Obsession

| Field | Value |
|---|---|
| **Smell name** | Primitive Obsession |
| **Expected smell location** | `Inventory.PackagingCalculator` module — physical measurements throughout |
| **Affected functions** | `compute_shipping_cost/3`, `classify_package/3`, `fits_in_box/4`, `calculate_volumetric_weight/3` |
| **Short explanation** | Physical dimensions (length, width, height) and weight are each passed as plain `float` values with an implicit unit (centimetres / kilograms) rather than structured types such as `%Dimension{value: float(), unit: :cm | :m | :in}` and `%Weight{value: float(), unit: :kg | :lb | :g}`. This makes unit conversion implicit, allows mixing incompatible units silently, and forces repeated unit-assumption comments throughout the code. |

```elixir
defmodule Inventory.PackagingCalculator do
  @moduledoc """
  Calculates shipping costs, classifies packages by carrier category,
  checks dimensional fit, and computes volumetric weight for outbound
  fulfilment operations.
  """

  require Logger

  alias Inventory.Repo
  alias Inventory.Schema.{ShippingRate, BoxTemplate}

  @volumetric_divisor 5000.0
  @max_weight_kg 30.0
  @max_dimension_cm 150.0

  # VALIDATION: SMELL START - Primitive Obsession
  # VALIDATION: This is a smell because physical measurements are passed as
  # plain `float` values with implicit units (always cm for dimensions, always
  # kg for weight). A dedicated %Dimension{value: float(), unit: :cm} and
  # %Weight{value: float(), unit: :kg} would make units explicit, enable safe
  # unit conversion, and prevent mixing cm with inches silently.

  @spec compute_shipping_cost(float(), float(), float()) ::
          {:ok, float()} | {:error, term()}
  def compute_shipping_cost(length_cm, width_cm, height_cm)
      when is_float(length_cm) and is_float(width_cm) and is_float(height_cm) do
    with :ok <- validate_dimension(length_cm, :length),
         :ok <- validate_dimension(width_cm, :width),
         :ok <- validate_dimension(height_cm, :height) do
      volumetric_kg = calculate_volumetric_weight(length_cm, width_cm, height_cm)
      category = classify_by_volume(volumetric_kg)

      rate =
        Repo.one(
          from r in ShippingRate,
            where: r.category == ^category,
            order_by: [asc: r.base_price],
            limit: 1
        )

      case rate do
        nil ->
          {:error, :no_rate_found}

        rate ->
          cost = Float.round(rate.base_price + volumetric_kg * rate.per_kg_rate, 2)
          Logger.debug("Shipping cost: #{length_cm}×#{width_cm}×#{height_cm}cm → #{volumetric_kg}kg vol → #{cost}")
          {:ok, cost}
      end
    end
  end

  @spec classify_package(float(), float(), float()) :: atom()
  def classify_package(length_cm, width_cm, height_cm)
      when is_float(length_cm) and is_float(width_cm) and is_float(height_cm) do
    volumetric_kg = calculate_volumetric_weight(length_cm, width_cm, height_cm)

    cond do
      volumetric_kg <= 1.0 -> :letter
      volumetric_kg <= 5.0 -> :small_parcel
      volumetric_kg <= 20.0 -> :medium_parcel
      true -> :large_parcel
    end
  end

  @spec fits_in_box?(float(), float(), float(), String.t()) :: boolean()
  def fits_in_box?(item_length_cm, item_width_cm, item_height_cm, box_template_name)
      when is_float(item_length_cm) and is_float(item_width_cm) and is_float(item_height_cm) do
    case Repo.get_by(BoxTemplate, name: box_template_name) do
      nil ->
        false

      box ->
        sorted_item = Enum.sort([item_length_cm, item_width_cm, item_height_cm], :desc)
        sorted_box = Enum.sort([box.length_cm, box.width_cm, box.height_cm], :desc)

        Enum.zip(sorted_item, sorted_box)
        |> Enum.all?(fn {item_dim, box_dim} -> item_dim <= box_dim end)
    end
  end

  @spec calculate_volumetric_weight(float(), float(), float()) :: float()
  def calculate_volumetric_weight(length_cm, width_cm, height_cm)
      when is_float(length_cm) and is_float(width_cm) and is_float(height_cm) do
    Float.round(length_cm * width_cm * height_cm / @volumetric_divisor, 3)
  end

  @spec billable_weight(float(), float(), float(), float()) :: float()
  def billable_weight(length_cm, width_cm, height_cm, actual_weight_kg)
      when is_float(length_cm) and is_float(width_cm) and
           is_float(height_cm) and is_float(actual_weight_kg) do
    vol_weight = calculate_volumetric_weight(length_cm, width_cm, height_cm)
    max(vol_weight, actual_weight_kg)
  end

  # VALIDATION: SMELL END

  ## Private helpers

  defp validate_dimension(dim, axis) when dim <= 0.0,
    do: {:error, {:non_positive_dimension, axis, dim}}

  defp validate_dimension(dim, axis) when dim > @max_dimension_cm,
    do: {:error, {:dimension_exceeds_limit, axis, dim, @max_dimension_cm}}

  defp validate_dimension(_dim, _axis), do: :ok

  defp classify_by_volume(volumetric_kg) do
    cond do
      volumetric_kg <= 1.0 -> :letter
      volumetric_kg <= 5.0 -> :small_parcel
      volumetric_kg <= 20.0 -> :medium_parcel
      true -> :large_parcel
    end
  end
end
```
