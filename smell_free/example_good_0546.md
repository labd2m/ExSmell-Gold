# File: `example_good_546.md`

```elixir
defmodule Shipping.RateCalculator do
  @moduledoc """
  Calculates shipping rates across multiple carriers for a given
  shipment specification, returning ranked options by price and
  estimated delivery time.

  Carrier adapters are injected so the module is testable without
  live API calls. Adapters are called concurrently with a shared
  deadline to keep total quote time bounded.
  """

  require Logger

  @default_quote_timeout_ms 5_000

  @type address :: %{
          required(:country_code) => String.t(),
          required(:postal_code) => String.t(),
          required(:city) => String.t()
        }

  @type parcel :: %{
          required(:weight_grams) => pos_integer(),
          required(:length_cm) => pos_integer(),
          required(:width_cm) => pos_integer(),
          required(:height_cm) => pos_integer()
        }

  @type shipment :: %{
          required(:origin) => address(),
          required(:destination) => address(),
          required(:parcels) => [parcel()],
          optional(:declared_value_cents) => pos_integer()
        }

  @type rate_quote :: %{
          carrier: String.t(),
          service: String.t(),
          price_cents: non_neg_integer(),
          currency: String.t(),
          estimated_days: pos_integer() | nil,
          guaranteed: boolean()
        }

  @type quote_result ::
          {:ok, [rate_quote()]}
          | {:error, :no_rates_available}

  @doc """
  Fetches rate quotes for `shipment` from all `carrier_adapters`.

  Adapters are called concurrently. Any adapter that exceeds
  `:quote_timeout_ms` or returns an error is silently excluded
  from results so a single carrier failure does not block the response.

  Returns `{:ok, quotes}` sorted cheapest first, or
  `{:error, :no_rates_available}` when no adapter responds.
  """
  @spec quote(shipment(), [module()], keyword()) :: quote_result()
  def quote(shipment, carrier_adapters, opts \\ [])
      when is_map(shipment) and is_list(carrier_adapters) do
    timeout_ms = Keyword.get(opts, :quote_timeout_ms, @default_quote_timeout_ms)

    quotes =
      carrier_adapters
      |> Enum.map(&Task.async(fn -> fetch_quotes(&1, shipment) end))
      |> Enum.flat_map(&await_quote(&1, timeout_ms))
      |> Enum.sort_by(& &1.price_cents)

    case quotes do
      [] -> {:error, :no_rates_available}
      _ -> {:ok, quotes}
    end
  end

  @doc """
  Filters a list of rate quotes to those deliverable within `max_days`.
  """
  @spec filter_by_delivery(quote_result(), pos_integer()) :: quote_result()
  def filter_by_delivery({:ok, quotes}, max_days) when is_integer(max_days) and max_days > 0 do
    filtered =
      Enum.filter(quotes, fn q ->
        is_nil(q.estimated_days) or q.estimated_days <= max_days
      end)

    case filtered do
      [] -> {:error, :no_rates_available}
      _ -> {:ok, filtered}
    end
  end

  def filter_by_delivery({:error, _} = error, _max_days), do: error

  @doc """
  Returns only guaranteed-delivery options from a quote result.
  """
  @spec guaranteed_only(quote_result()) :: quote_result()
  def guaranteed_only({:ok, quotes}) do
    case Enum.filter(quotes, & &1.guaranteed) do
      [] -> {:error, :no_rates_available}
      guaranteed -> {:ok, guaranteed}
    end
  end

  def guaranteed_only({:error, _} = error), do: error

  @doc """
  Computes the volumetric weight in grams for a parcel using the standard
  5000 cm³/kg divisor.
  """
  @spec volumetric_weight_grams(parcel()) :: pos_integer()
  def volumetric_weight_grams(%{length_cm: l, width_cm: w, height_cm: h}) do
    round(l * w * h / 5_000 * 1_000)
  end

  @doc """
  Returns the chargeable weight for a parcel — the greater of actual
  and volumetric weight.
  """
  @spec chargeable_weight_grams(parcel()) :: pos_integer()
  def chargeable_weight_grams(%{weight_grams: actual} = parcel) do
    max(actual, volumetric_weight_grams(parcel))
  end

  defp fetch_quotes(adapter, shipment) do
    case adapter.get_rates(shipment) do
      {:ok, rates} ->
        rates

      {:error, reason} ->
        Logger.warning("Carrier adapter #{adapter} failed: #{inspect(reason)}")
        []
    end
  rescue
    exception ->
      Logger.error("Carrier adapter #{adapter} raised: #{Exception.message(exception)}")
      []
  end

  defp await_quote(task, timeout_ms) do
    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, quotes} -> quotes
      nil -> []
    end
  end
end
```
