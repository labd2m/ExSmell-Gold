# Annotated Example — Speculative Assumptions

## Metadata

- **Smell name:** Speculative Assumptions
- **Expected smell location:** `resolve_carrier/1` function, lines ~45–60
- **Affected function(s):** `resolve_carrier/1`
- **Short explanation:** `resolve_carrier/1` returns a default carrier atom (`:unknown`) when the shipment data does not match any known carrier pattern. This speculative fallback allows processing to continue silently with an invalid carrier, rather than crashing and letting the supervisor handle the unexpected state.

---

```elixir
defmodule Logistics.ShipmentClassifier do
  @moduledoc """
  Classifies inbound shipment records received from the warehouse management
  system and routes them to the appropriate carrier processing pipeline.
  """

  require Logger

  @known_carriers [:fedex, :ups, :dhl, :usps, :tnt]

  @carrier_prefixes %{
    "1Z"  => :ups,
    "7489" => :dhl,
    "9400" => :usps,
    "6129" => :fedex,
    "TNT"  => :tnt
  }

  @doc """
  Classifies a shipment and returns an enriched map ready for
  downstream pipeline processing.
  """
  def classify(shipment) when is_map(shipment) do
    tracking_number = Map.fetch!(shipment, "tracking_number")
    carrier         = resolve_carrier(tracking_number)
    priority        = resolve_priority(shipment)

    shipment
    |> Map.put(:carrier, carrier)
    |> Map.put(:priority, priority)
    |> Map.put(:classified_at, DateTime.utc_now())
  end

  @doc """
  Resolves the carrier from a tracking number by matching known prefixes.
  Returns the carrier atom or `:unknown` if no prefix matches.
  """

  # VALIDATION: SMELL START - Speculative Assumptions
  # VALIDATION: This is a smell because `resolve_carrier/1` silently returns
  # `:unknown` when no carrier prefix matches the tracking number. The function
  # makes an unplanned speculative assumption: it assumes downstream code can
  # meaningfully handle an `:unknown` carrier, when in reality there is no
  # planned processing pipeline for that value. Instead of crashing to surface
  # the unexpected tracking number format, the function allows a shipment with
  # an invalid carrier to flow through the system, potentially causing silent
  # misrouting or data corruption downstream.
  def resolve_carrier(tracking_number) when is_binary(tracking_number) do
    Enum.find_value(@carrier_prefixes, :unknown, fn {prefix, carrier} ->
      if String.starts_with?(tracking_number, prefix), do: carrier
    end)
  end
  # VALIDATION: SMELL END

  @doc """
  Resolves the shipping priority from the shipment metadata.
  """
  def resolve_priority(%{"priority" => "express"}), do: :express
  def resolve_priority(%{"priority" => "overnight"}), do: :overnight
  def resolve_priority(%{"priority" => "standard"}), do: :standard

  def resolve_priority(%{"priority" => other}) do
    raise ArgumentError, "unrecognised priority level: #{inspect(other)}"
  end

  def resolve_priority(_shipment), do: :standard

  @doc """
  Routes the classified shipment to the correct carrier handler module.
  """
  def route(%{carrier: :fedex} = shipment),  do: Logistics.Carriers.FedEx.handle(shipment)
  def route(%{carrier: :ups} = shipment),    do: Logistics.Carriers.UPS.handle(shipment)
  def route(%{carrier: :dhl} = shipment),    do: Logistics.Carriers.DHL.handle(shipment)
  def route(%{carrier: :usps} = shipment),   do: Logistics.Carriers.USPS.handle(shipment)
  def route(%{carrier: :tnt} = shipment),    do: Logistics.Carriers.TNT.handle(shipment)

  def route(%{carrier: unknown_carrier}) do
    raise RuntimeError,
      "no routing rule for carrier: #{inspect(unknown_carrier)}"
  end

  @doc """
  Returns true only if the carrier is one of the officially supported carriers.
  """
  def supported_carrier?(carrier), do: carrier in @known_carriers

  @doc """
  Batch-classifies a list of raw shipment maps.
  """
  def classify_all(shipments) when is_list(shipments) do
    Enum.map(shipments, &classify/1)
  end
end
```
