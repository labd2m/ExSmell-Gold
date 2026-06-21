```elixir
defmodule MyApp.Logistics.CarrierSelector do
  @moduledoc """
  Selects the optimal shipping carrier for a parcel given a set of
  business rules and live rate quotes. Selection criteria are evaluated
  in a priority-weighted order: mandatory rules first, then cost and
  speed optimisation according to the service level requested by the
  customer.

  Carrier adapters are injected via configuration, keeping this module
  independent of any specific carrier SDK.
  """

  alias MyApp.Shipping.{Parcel, Address, Rate}

  @type service_level :: :economy | :standard | :express | :overnight
  @type selection_result :: %{
          carrier: String.t(),
          service: String.t(),
          estimated_days: pos_integer(),
          total_cents: pos_integer(),
          reason: String.t()
        }

  @doc """
  Selects the best carrier for `parcel` shipping to `destination` at
  `service_level`. Returns `{:error, :no_rates_available}` when all
  configured carriers fail to respond or no rate meets the service level.
  """
  @spec select(Parcel.t(), Address.t(), service_level()) ::
          {:ok, selection_result()} | {:error, :no_rates_available}
  def select(%Parcel{} = parcel, %Address{} = destination, service_level) do
    case MyApp.Shipping.RateCalculator.available_rates(parcel, destination) do
      {:ok, []} ->
        {:error, :no_rates_available}

      {:ok, rates} ->
        rates
        |> filter_by_service_level(service_level)
        |> apply_exclusions(destination)
        |> rank_rates(service_level)
        |> pick_best()
    end
  end

  @spec filter_by_service_level([Rate.t()], service_level()) :: [Rate.t()]
  defp filter_by_service_level(rates, :economy) do
    Enum.filter(rates, &(&1.estimated_days >= 5))
  end

  defp filter_by_service_level(rates, :standard) do
    Enum.filter(rates, &(&1.estimated_days in 2..5))
  end

  defp filter_by_service_level(rates, :express) do
    Enum.filter(rates, &(&1.estimated_days in 1..2))
  end

  defp filter_by_service_level(rates, :overnight) do
    Enum.filter(rates, &(&1.estimated_days == 1))
  end

  @spec apply_exclusions([Rate.t()], Address.t()) :: [Rate.t()]
  defp apply_exclusions(rates, destination) do
    Enum.reject(rates, fn rate ->
      excluded_carrier_for_region?(rate.carrier, destination.country)
    end)
  end

  @spec excluded_carrier_for_region?(String.t(), String.t()) :: boolean()
  defp excluded_carrier_for_region?("USPS", country) when country != "US", do: true
  defp excluded_carrier_for_region?(_carrier, _country), do: false

  @spec rank_rates([Rate.t()], service_level()) :: [Rate.t()]
  defp rank_rates(rates, :economy), do: Enum.sort_by(rates, & &1.total_cents)
  defp rank_rates(rates, :overnight), do: Enum.sort_by(rates, & &1.total_cents)
  defp rank_rates(rates, _level) do
    Enum.sort_by(rates, fn r -> {r.estimated_days, r.total_cents} end)
  end

  @spec pick_best([Rate.t()]) ::
          {:ok, selection_result()} | {:error, :no_rates_available}
  defp pick_best([]), do: {:error, :no_rates_available}

  defp pick_best([best | _]) do
    {:ok, %{
      carrier: best.carrier,
      service: best.service,
      estimated_days: best.estimated_days,
      total_cents: best.total_cents,
      reason: "best_available_for_service_level"
    }}
  end
end
```
