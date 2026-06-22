```elixir
defmodule Forecasting.DemandPredictor do
  @moduledoc """
  Produces demand forecasts for inventory items using a weighted
  moving average over historical sales data.

  All computation is pure; this module performs no I/O. Callers
  supply historical sales windows and receive forecast structs.
  """

  alias Forecasting.SalesWindow
  alias Forecasting.Forecast

  @type sku :: String.t()
  @type period_count :: pos_integer()

  @default_periods 4
  @min_data_points 2

  @doc """
  Produces a demand forecast for the given SKU using the supplied
  historical sales windows.

  Windows must be ordered oldest-first. A minimum of two data points
  is required for a valid forecast. Returns `{:error, :insufficient_data}`
  if fewer than two windows are provided.
  """
  @spec forecast(sku(), [SalesWindow.t()], period_count()) ::
          {:ok, Forecast.t()} | {:error, :insufficient_data | :empty_sku}
  def forecast(sku, windows, periods \\ @default_periods)

  def forecast(sku, _windows, _periods) when not is_binary(sku) or byte_size(sku) == 0 do
    {:error, :empty_sku}
  end

  def forecast(_sku, windows, _periods) when length(windows) < @min_data_points do
    {:error, :insufficient_data}
  end

  def forecast(sku, windows, periods)
      when is_binary(sku) and is_list(windows) and is_integer(periods) and periods > 0 do
    weights = generate_weights(length(windows))
    weighted_avg = compute_weighted_average(windows, weights)
    trend = compute_trend(windows)
    projected = project_forward(weighted_avg, trend, periods)
    confidence = compute_confidence(windows, weighted_avg)

    forecast = %Forecast{
      sku: sku,
      projected_units: projected,
      confidence_score: confidence,
      periods_ahead: periods,
      generated_at: DateTime.utc_now()
    }

    {:ok, forecast}
  end

  @spec generate_weights(pos_integer()) :: [float()]
  defp generate_weights(count) do
    raw = Enum.map(1..count, fn i -> i * 1.0 end)
    total = Enum.sum(raw)
    Enum.map(raw, &(&1 / total))
  end

  @spec compute_weighted_average([SalesWindow.t()], [float()]) :: float()
  defp compute_weighted_average(windows, weights) do
    windows
    |> Enum.zip(weights)
    |> Enum.reduce(0.0, fn {window, weight}, acc ->
      acc + window.units_sold * weight
    end)
  end

  @spec compute_trend([SalesWindow.t()]) :: float()
  defp compute_trend(windows) do
    values = Enum.map(windows, & &1.units_sold)
    n = length(values)
    first_half_avg = values |> Enum.take(div(n, 2)) |> average()
    second_half_avg = values |> Enum.drop(div(n, 2)) |> average()
    (second_half_avg - first_half_avg) / max(1, div(n, 2))
  end

  @spec project_forward(float(), float(), pos_integer()) :: float()
  defp project_forward(base, trend, periods) do
    Float.round(max(0.0, base + trend * periods), 2)
  end

  @spec compute_confidence([SalesWindow.t()], float()) :: float()
  defp compute_confidence(windows, predicted_avg) do
    actuals = Enum.map(windows, & &1.units_sold)
    mean = average(actuals)
    variance = Enum.reduce(actuals, 0.0, fn v, acc -> acc + (v - mean) ** 2 end) / length(actuals)
    std_dev = :math.sqrt(variance)

    relative_error = if predicted_avg > 0, do: std_dev / predicted_avg, else: 1.0
    Float.round(max(0.0, min(1.0, 1.0 - relative_error)), 4)
  end

  @spec average([number()]) :: float()
  defp average([]), do: 0.0
  defp average(values), do: Enum.sum(values) / length(values)
end
```
