# Annotated Example – Bad Code (Feature Envy)

## Metadata

| Field | Value |
|---|---|
| **Smell** | Feature Envy |
| **Expected Smell Location** | `Logistics.ParcelDispatcher.assess_delivery_risk/1` |
| **Affected Function(s)** | `assess_delivery_risk/1` |
| **Explanation** | `assess_delivery_risk/1` lives in `Logistics.ParcelDispatcher` but all of its logic revolves around fetching and inspecting data from `Logistics.Parcel` — calling `Parcel.get!/1`, `Parcel.declared_value/1`, `Parcel.requires_signature?/1`, `Parcel.is_fragile?/1`, and reading struct fields directly. The function is more interested in `Parcel` than in `ParcelDispatcher`. |

```elixir
defmodule Logistics.Parcel do
  @moduledoc "Represents a parcel in the logistics system."

  defstruct [
    :id,
    :tracking_number,
    :sender_id,
    :recipient_id,
    :weight_kg,
    :dimensions_cm,
    :contents_category,
    :declared_value_usd,
    :insurance_tier,
    :fragile_flag,
    :signature_required,
    :destination_country,
    :dispatch_at
  ]

  def get!(id) do
    %__MODULE__{
      id: id,
      tracking_number: "TRK-20240315-0042",
      sender_id: "SENDER-001",
      recipient_id: "RECIPIENT-099",
      weight_kg: 4.7,
      dimensions_cm: %{length: 30, width: 20, height: 15},
      contents_category: :electronics,
      declared_value_usd: 850.0,
      insurance_tier: :standard,
      fragile_flag: true,
      signature_required: true,
      destination_country: "DE",
      dispatch_at: ~U[2024-03-15 08:00:00Z]
    }
  end

  def declared_value(%__MODULE__{declared_value_usd: v}), do: v

  def requires_signature?(%__MODULE__{signature_required: true}), do: true
  def requires_signature?(_), do: false

  def is_fragile?(%__MODULE__{fragile_flag: true}), do: true
  def is_fragile?(_), do: false

  def international?(%__MODULE__{destination_country: country}) do
    country not in ["US", "PR", "VI"]
  end

  def oversize?(%__MODULE__{dimensions_cm: %{length: l, width: w, height: h}}) do
    l + 2 * w + 2 * h > 165
  end
end

defmodule Logistics.DispatchRoute do
  @moduledoc "Represents a planned dispatch route."

  defstruct [:id, :carrier, :estimated_days, :max_weight_kg, :international_allowed]

  def find_for_country("DE"), do: %__MODULE__{id: "R-EU-01", carrier: "DHL", estimated_days: 5, max_weight_kg: 30.0, international_allowed: true}
  def find_for_country(_), do: %__MODULE__{id: "R-DOM-01", carrier: "FedEx", estimated_days: 3, max_weight_kg: 70.0, international_allowed: false}
end

defmodule Logistics.ParcelDispatcher do
  @moduledoc """
  Handles the dispatch workflow for parcels, including route selection
  and risk evaluation before shipment is confirmed.
  """

  alias Logistics.{Parcel, DispatchRoute}
  require Logger

  @high_value_threshold 500.0
  @risk_levels [:low, :medium, :high, :critical]

  @doc """
  Dispatches a parcel by evaluating its risk profile and selecting an
  appropriate route.
  """
  def dispatch(parcel_id) do
    parcel = Parcel.get!(parcel_id)
    risk   = assess_delivery_risk(parcel_id)
    route  = DispatchRoute.find_for_country(parcel.destination_country)

    Logger.info("Dispatching parcel #{parcel_id} via #{route.carrier}, risk=#{risk}")

    cond do
      risk == :critical ->
        {:error, :parcel_requires_manual_review}

      route.max_weight_kg < parcel.weight_kg ->
        {:error, :parcel_exceeds_route_weight_limit}

      true ->
        {:ok, %{tracking: parcel.tracking_number, carrier: route.carrier, eta_days: route.estimated_days}}
    end
  end

  # VALIDATION: SMELL START - Feature Envy
  # VALIDATION: This is a smell because `assess_delivery_risk/1` belongs to
  # VALIDATION: `ParcelDispatcher` but every single operation it performs is on
  # VALIDATION: `Parcel` data: it calls `Parcel.get!/1`, `Parcel.declared_value/1`,
  # VALIDATION: `Parcel.requires_signature?/1`, `Parcel.is_fragile?/1`, and
  # VALIDATION: `Parcel.international?/1`. The function uses nothing from its own
  # VALIDATION: module and should be moved to `Parcel`.
  defp assess_delivery_risk(parcel_id) do
    parcel = Parcel.get!(parcel_id)

    score =
      0
      |> then(fn s -> if Parcel.declared_value(parcel) > @high_value_threshold, do: s + 2, else: s end)
      |> then(fn s -> if Parcel.requires_signature?(parcel), do: s + 1, else: s end)
      |> then(fn s -> if Parcel.is_fragile?(parcel), do: s + 1, else: s end)
      |> then(fn s -> if Parcel.international?(parcel), do: s + 1, else: s end)
      |> then(fn s -> if Parcel.oversize?(parcel), do: s + 2, else: s end)

    cond do
      score >= 6 -> :critical
      score >= 4 -> :high
      score >= 2 -> :medium
      true       -> :low
    end
  end
  # VALIDATION: SMELL END

  defp log_dispatch_failure(parcel_id, reason) do
    Logger.warning("Dispatch failed for parcel #{parcel_id}: #{inspect(reason)}")
  end
end
```
