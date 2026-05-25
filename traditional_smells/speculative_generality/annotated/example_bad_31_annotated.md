# Annotated Example — Speculative Generality

## Metadata

- **Smell name:** Speculative Generality
- **Expected smell location:** `select_routing_profile/1` in `Logistics.ShipmentRouter`
- **Affected function(s):** `select_routing_profile/1`
- **Short explanation:** `select_routing_profile/1` destructures `shipment_class` from the shipment and uses it in a `case` expression, but the only clause is a wildcard that always returns the same `:standard` profile. The function was written speculatively to return different routing profiles (e.g., `:express`, `:freight`, `:hazmat`) based on shipment class, but that differentiation was never implemented.

---

```elixir
defmodule Logistics.ShipmentRouter do
  @moduledoc """
  Determines routing decisions for outbound shipments.

  Routing considers the shipment class, destination, carrier capabilities,
  and current hub capacity before assigning a route and carrier.
  """

  alias Logistics.{Shipment, HubCapacity, CarrierPool, RouteAssignment}

  require Logger

  @spec route(Shipment.t()) :: {:ok, RouteAssignment.t()} | {:error, atom()}
  def route(%Shipment{} = shipment) do
    with {:ok, profile} <- select_routing_profile(shipment),
         {:ok, hub} <- HubCapacity.find_available_hub(shipment.origin_region, profile),
         {:ok, carrier} <- CarrierPool.select(shipment, hub, profile),
         {:ok, assignment} <- RouteAssignment.create(shipment, hub, carrier, profile) do
      Logger.info(
        "Shipment routed id=#{shipment.id} hub=#{hub.code} carrier=#{carrier.name} profile=#{profile}"
      )

      {:ok, assignment}
    else
      {:error, :no_hub_capacity} ->
        Logger.warning("No hub capacity for shipment=#{shipment.id}")
        {:error, :no_hub_capacity}

      {:error, reason} ->
        Logger.error("Routing failed for shipment=#{shipment.id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @spec reroute(String.t(), String.t()) :: {:ok, RouteAssignment.t()} | {:error, atom()}
  def reroute(shipment_id, reason) do
    with {:ok, shipment} <- Shipment.fetch(shipment_id),
         :ok <- RouteAssignment.cancel_current(shipment_id, reason),
         {:ok, assignment} <- route(shipment) do
      Logger.info("Shipment rerouted id=#{shipment_id} reason=#{reason}")
      {:ok, assignment}
    end
  end

  # VALIDATION: SMELL START - Speculative Generality
  # VALIDATION: This is a smell because `shipment_class` is extracted from the 
  # shipment struct and passed into a `case` expression intended to return a 
  # different routing profile per class. However, the only clause is a wildcard 
  # that always returns `:standard`. The developer planned to add `:express`, 
  # `:freight`, and `:hazmat` branches later, but never did. Every shipment class 
  # gets the same profile, making the extraction and case speculative dead structure.
  defp select_routing_profile(%{shipment_class: shipment_class}) do
    profile =
      case shipment_class do
        _ -> :standard
      end

    {:ok, profile}
  end
  # VALIDATION: SMELL END

  defp validate_routable(%Shipment{status: :pending}), do: :ok
  defp validate_routable(%Shipment{status: :rerouting}), do: :ok
  defp validate_routable(_shipment), do: {:error, :not_routable}
end

defmodule Logistics.HubCapacity do
  def find_available_hub(region, _profile) do
    case :ets.match(:hubs, {:"$1", %{region: region, available: true}}) do
      [[hub_code] | _] -> {:ok, %{code: hub_code, region: region}}
      [] -> {:error, :no_hub_capacity}
    end
  end
end

defmodule Logistics.CarrierPool do
  def select(%{weight_kg: weight, declared_value: value}, hub, _profile) do
    carriers = :ets.lookup(:carriers, hub.code)

    case Enum.find(carriers, fn {_code, c} -> c.max_weight >= weight and c.insured_up_to >= value end) do
      {_code, carrier} -> {:ok, carrier}
      nil -> {:error, :no_carrier_available}
    end
  end
end
```
