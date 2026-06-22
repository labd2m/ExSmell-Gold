```elixir
defmodule Shipping.CarrierRateCalculator do
  @moduledoc """
  Multi-carrier shipping rate calculator with pluggable carrier adapters.

  Queries all registered carrier adapters in parallel and returns a ranked
  list of rate quotes sorted by total cost. Carrier timeouts are handled
  gracefully; failing carriers are excluded from results rather than
  propagating errors.
  """

  alias Shipping.{CarrierAdapter, RateQuote}

  @carrier_timeout_ms 5_000

  @type shipment :: %{
          origin_zip: String.t(),
          destination_zip: String.t(),
          weight_grams: pos_integer(),
          dimensions_cm: %{length: float(), width: float(), height: float()},
          declared_value_cents: non_neg_integer()
        }

  @type rate_result :: {:ok, [RateQuote.t()]} | {:error, :no_rates_available}

  @doc """
  Fetches and ranks rate quotes from all configured carrier adapters.

  Carriers are queried concurrently with a per-carrier timeout. If no
  carrier returns a valid quote, `{:error, :no_rates_available}` is returned.
  """
  @spec fetch_rates(shipment(), [module()]) :: rate_result()
  def fetch_rates(%{} = shipment, carrier_adapters) when is_list(carrier_adapters) do
    quotes =
      carrier_adapters
      |> Task.async_stream(
        fn adapter -> query_carrier(adapter, shipment) end,
        timeout: @carrier_timeout_ms,
        on_timeout: :kill_task
      )
      |> Enum.flat_map(&extract_successful_quotes/1)
      |> Enum.sort_by(fn %{total_cents: total} -> total end)

    case quotes do
      [] -> {:error, :no_rates_available}
      results -> {:ok, results}
    end
  end

  @doc """
  Returns the single cheapest quote across all carriers, or an error if none available.
  """
  @spec cheapest_rate(shipment(), [module()]) :: {:ok, RateQuote.t()} | {:error, :no_rates_available}
  def cheapest_rate(shipment, carrier_adapters) do
    with {:ok, [cheapest | _]} <- fetch_rates(shipment, carrier_adapters) do
      {:ok, cheapest}
    end
  end

  defp query_carrier(adapter, shipment) do
    case adapter.get_rates(shipment) do
      {:ok, quotes} -> {:ok, quotes}
      {:error, _reason} -> {:ok, []}
    end
  rescue
    _ -> {:ok, []}
  end

  defp extract_successful_quotes({:ok, {:ok, quotes}}), do: quotes
  defp extract_successful_quotes({:ok, _}), do: []
  defp extract_successful_quotes({:exit, _}), do: []
end

defmodule Shipping.CarrierAdapter do
  @moduledoc """
  Behaviour contract for shipping carrier rate adapters.
  """

  @type shipment :: map()
  @type rate_quote :: map()

  @callback get_rates(shipment()) :: {:ok, [rate_quote()]} | {:error, term()}
end

defmodule Shipping.RateQuote do
  @moduledoc """
  Structured rate quote returned by a carrier adapter.
  """

  @enforce_keys [:carrier, :service_name, :estimated_days, :total_cents]
  defstruct [:carrier, :service_name, :estimated_days, :total_cents, :tracking_available]

  @type t :: %__MODULE__{
          carrier: String.t(),
          service_name: String.t(),
          estimated_days: pos_integer(),
          total_cents: pos_integer(),
          tracking_available: boolean()
        }
end
```
