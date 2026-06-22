```elixir
defmodule Supply.Forecasting.DemandProjector do
  @moduledoc """
  Projects future demand for inventory items using simple exponential smoothing.
  Historical sales data is validated and smoothed; projections are generated
  for a configurable horizon with confidence interval bounds.
  """

  @type sales_record :: %{period: pos_integer(), units_sold: non_neg_integer()}
  @type projection :: %{
          period: pos_integer(),
          projected_units: float(),
          lower_bound: float(),
          upper_bound: float()
        }
  @type result :: %{
          smoothed_series: [float()],
          projections: [projection()],
          alpha: float()
        }

  @default_alpha 0.3
  @default_confidence_factor 1.645

  @doc """
  Projects demand for `horizon` future periods from `history`.

  ## Options
    - `:alpha` - exponential smoothing factor 0.0 < alpha <= 1.0 (default: 0.3)
    - `:confidence_factor` - z-score for confidence interval (default: 1.645 for 90%)
  """
  @spec project([sales_record()], pos_integer(), keyword()) ::
          {:ok, result()} | {:error, String.t()}
  def project(history, horizon, opts \\ [])
      when is_list(history) and is_integer(horizon) and horizon > 0 do
    alpha = Keyword.get(opts, :alpha, @default_alpha)
    cf = Keyword.get(opts, :confidence_factor, @default_confidence_factor)

    with :ok <- validate_history(history),
         :ok <- validate_alpha(alpha) do
      sorted = Enum.sort_by(history, fn r -> r.period end)
      values = Enum.map(sorted, fn r -> r.units_sold * 1.0 end)
      smoothed = exponential_smooth(values, alpha)
      std_dev = standard_deviation(values, smoothed)
      last_smooth = List.last(smoothed)
      last_period = sorted |> List.last() |> Map.fetch!(:period)
      projections = project_periods(last_smooth, last_period, horizon, std_dev, cf)

      {:ok, %{smoothed_series: smoothed, projections: projections, alpha: alpha}}
    end
  end

  defp exponential_smooth([first | rest], alpha) do
    Enum.reduce(rest, [first], fn value, [prev | _] = acc ->
      smoothed = alpha * value + (1.0 - alpha) * prev
      [smoothed | acc]
    end)
    |> Enum.reverse()
  end

  defp project_periods(last_smooth, last_period, horizon, std_dev, cf) do
    Enum.map(1..horizon, fn offset ->
      period = last_period + offset
      interval = cf * std_dev * :math.sqrt(offset * 1.0)

      %{
        period: period,
        projected_units: Float.round(last_smooth, 2),
        lower_bound: Float.round(max(last_smooth - interval, 0.0), 2),
        upper_bound: Float.round(last_smooth + interval, 2)
      }
    end)
  end

  defp standard_deviation(actuals, smoothed) do
    errors = Enum.zip(actuals, smoothed) |> Enum.map(fn {a, s} -> (a - s) * (a - s) end)
    mean_sq_error = Enum.sum(errors) / max(length(errors), 1)
    :math.sqrt(mean_sq_error)
  end

  defp validate_history([]), do: {:error, "history must contain at least one sales record"}

  defp validate_history(history) do
    invalid = Enum.find(history, fn r -> not valid_record?(r) end)

    if is_nil(invalid) do
      :ok
    else
      {:error, "invalid sales record: #{inspect(invalid)}"}
    end
  end

  defp valid_record?(%{period: p, units_sold: u})
       when is_integer(p) and p > 0 and is_integer(u) and u >= 0,
       do: true

  defp valid_record?(_), do: false

  defp validate_alpha(alpha) when is_float(alpha) and alpha > 0.0 and alpha <= 1.0, do: :ok
  defp validate_alpha(_), do: {:error, "alpha must be a float between 0.0 (exclusive) and 1.0 (inclusive)"}
end
```
