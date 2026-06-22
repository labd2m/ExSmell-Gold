```elixir
defmodule Logistics.Routes.CostEstimator do
  @moduledoc """
  Estimates shipping costs for logistics routes using a configurable
  rate table and distance-based surcharge model.
  All monetary values are in integer cents.
  """

  alias Logistics.Routes.{RateTable, Segment, Surcharge}

  @type estimate :: %{
          base_cents: non_neg_integer(),
          surcharge_cents: non_neg_integer(),
          total_cents: non_neg_integer(),
          currency: String.t()
        }

  @doc """
  Estimates the shipping cost for a list of route segments.
  Returns `{:ok, estimate}` or `{:error, reason}` on invalid input.
  """
  @spec estimate([Segment.t()], RateTable.t(), keyword()) ::
          {:ok, estimate()} | {:error, String.t()}
  def estimate(segments, rate_table, opts \\ [])
      when is_list(segments) and is_map(rate_table) do
    currency = Keyword.get(opts, :currency, "USD")

    with :ok <- validate_segments(segments),
         {:ok, base_cents} <- compute_base_cost(segments, rate_table),
         {:ok, surcharge_cents} <- compute_surcharges(segments, rate_table, opts) do
      {:ok,
       %{
         base_cents: base_cents,
         surcharge_cents: surcharge_cents,
         total_cents: base_cents + surcharge_cents,
         currency: currency
       }}
    end
  end

  defp validate_segments([]), do: {:error, "at least one route segment is required"}

  defp validate_segments(segments) do
    invalid = Enum.find(segments, fn s -> not Segment.valid?(s) end)

    if is_nil(invalid) do
      :ok
    else
      {:error, "invalid segment: #{inspect(invalid)}"}
    end
  end

  defp compute_base_cost(segments, rate_table) do
    total =
      Enum.reduce_while(segments, {:ok, 0}, fn segment, {:ok, acc} ->
        case RateTable.rate_for(rate_table, segment.mode, segment.distance_km) do
          {:ok, rate_cents} -> {:cont, {:ok, acc + rate_cents}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    total
  end

  defp compute_surcharges(segments, rate_table, opts) do
    apply_fuel = Keyword.get(opts, :fuel_surcharge, true)
    apply_remote = Keyword.get(opts, :remote_area_surcharge, true)

    total =
      Enum.reduce_while(segments, {:ok, 0}, fn segment, {:ok, acc} ->
        with {:ok, fuel} <- maybe_fuel_surcharge(segment, rate_table, apply_fuel),
             {:ok, remote} <- maybe_remote_surcharge(segment, rate_table, apply_remote) do
          {:cont, {:ok, acc + fuel + remote}}
        else
          {:error, _} = err -> {:halt, err}
        end
      end)

    total
  end

  defp maybe_fuel_surcharge(_segment, _table, false), do: {:ok, 0}

  defp maybe_fuel_surcharge(segment, table, true) do
    Surcharge.fuel(table, segment)
  end

  defp maybe_remote_surcharge(_segment, _table, false), do: {:ok, 0}

  defp maybe_remote_surcharge(segment, table, true) do
    Surcharge.remote_area(table, segment)
  end
end
```
