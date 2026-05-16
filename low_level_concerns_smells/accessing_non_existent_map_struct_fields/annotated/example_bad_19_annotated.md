# Annotated Example 19

## Metadata

- **Smell name:** Accessing non-existent Map/Struct fields
- **Expected smell location:** `Shipping.LabelGenerator.generate/2`, lines where `parcel` map keys are accessed dynamically
- **Affected function(s):** `generate/2`
- **Short explanation:** `parcel[:weight_kg]`, `parcel[:dimensions]`, `parcel[:fragile]`, and `parcel[:declared_value]` use dynamic bracket access. When `:weight_kg` is absent, `nil` is passed into carrier rate calculation arithmetic, silently crashing or producing a `nil` rate. A missing `:fragile` flag goes undetected, potentially omitting required handling markings from the shipping label.

---

```elixir
defmodule Shipping.LabelGenerator do
  @moduledoc """
  Generates shipping labels by selecting a carrier, calculating rates,
  and rendering label data for physical printing or PDF output.
  """

  require Logger

  @carriers          [:dhl, :fedex, :ups, :correios]
  @fragile_surcharge 2.50
  @insurance_rate    0.015

  @type parcel :: %{optional(atom()) => term()}

  @type label :: %{
          tracking_number: String.t(),
          carrier: atom(),
          service_level: String.t(),
          rate: float(),
          fragile: boolean(),
          insured_value: float() | nil,
          origin: map(),
          destination: map(),
          generated_at: DateTime.t()
        }

  @spec generate(parcel(), map()) :: {:ok, label()} | {:error, String.t()}
  def generate(parcel, shipment_config) do
    # VALIDATION: SMELL START - Accessing non-existent Map/Struct fields
    # VALIDATION: This is a smell because `parcel[:weight_kg]`,
    # `parcel[:dimensions]`, `parcel[:fragile]`, and `parcel[:declared_value]`
    # use dynamic bracket access on a plain map. When `:weight_kg` is absent,
    # `nil` flows into `calculate_rate/4`, where `nil * rate_per_kg` raises
    # `ArithmeticError`. When `:fragile` is absent, the silent `nil` is
    # treated as falsy, so the fragile surcharge and special-handling markings
    # are omitted without any warning.
    weight_kg      = parcel[:weight_kg]
    dimensions     = parcel[:dimensions]
    fragile        = parcel[:fragile]
    declared_value = parcel[:declared_value]
    # VALIDATION: SMELL END

    with :ok <- validate_weight(weight_kg),
         :ok <- validate_dimensions(dimensions) do
      carrier       = select_carrier(shipment_config)
      service_level = Map.get(shipment_config, :service_level, "standard")
      rate          = calculate_rate(carrier, weight_kg, dimensions, fragile)

      insured_value =
        if declared_value && declared_value > 0 do
          declared_value * @insurance_rate
        end

      label = %{
        tracking_number: generate_tracking(carrier),
        carrier: carrier,
        service_level: service_level,
        rate: rate,
        fragile: fragile || false,
        insured_value: insured_value,
        origin: Map.fetch!(shipment_config, :origin),
        destination: Map.fetch!(shipment_config, :destination),
        generated_at: DateTime.utc_now()
      }

      Logger.info("Shipping label generated",
        tracking: label.tracking_number,
        carrier: carrier,
        rate: rate,
        fragile: label.fragile
      )

      {:ok, label}
    end
  end

  # ── Rate calculation ─────────────────────────────────────────────────────────

  defp calculate_rate(carrier, weight_kg, dimensions, fragile) do
    base_rate =
      case carrier do
        :dhl      -> weight_kg * 4.20
        :fedex    -> weight_kg * 4.85
        :ups      -> weight_kg * 4.60
        :correios -> weight_kg * 2.10
      end

    volume_surcharge =
      if dimensions do
        vol = dimensions.length * dimensions.width * dimensions.height
        if vol > 30_000, do: 5.0, else: 0.0
      else
        0.0
      end

    fragile_surcharge = if fragile, do: @fragile_surcharge, else: 0.0

    Float.round(base_rate + volume_surcharge + fragile_surcharge, 2)
  end

  # ── Validators ──────────────────────────────────────────────────────────────

  defp validate_weight(nil), do: {:error, "Parcel weight is required"}

  defp validate_weight(w) when is_number(w) and w > 0, do: :ok

  defp validate_weight(w), do: {:error, "Weight must be a positive number, got: #{inspect(w)}"}

  defp validate_dimensions(nil), do: :ok

  defp validate_dimensions(%{length: l, width: w, height: h})
       when is_number(l) and is_number(w) and is_number(h) and l > 0 and w > 0 and h > 0,
       do: :ok

  defp validate_dimensions(d),
    do: {:error, "Dimensions must have positive length/width/height, got: #{inspect(d)}"}

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp select_carrier(config) do
    preferred = Map.get(config, :preferred_carrier, :fedex)
    if preferred in @carriers, do: preferred, else: :fedex
  end

  defp generate_tracking(:correios) do
    code = :crypto.strong_rand_bytes(9) |> Base.encode16()
    "BR#{String.slice(code, 0, 9)}BR"
  end

  defp generate_tracking(carrier) do
    prefix = carrier |> Atom.to_string() |> String.upcase() |> String.slice(0, 2)
    code   = :crypto.strong_rand_bytes(10) |> Base.encode16()
    "#{prefix}#{String.slice(code, 0, 12)}"
  end
end
```
