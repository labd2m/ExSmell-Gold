# Annotated Example — Primitive Obsession

| Field | Value |
|---|---|
| **Smell name** | Primitive Obsession |
| **Expected smell location** | `Reporting.KPIDashboard` module — percentage/rate values throughout |
| **Affected functions** | `compute_conversion_rate/2`, `format_kpi_card/2`, `threshold_alert/3`, `aggregate_funnel/1` |
| **Short explanation** | Percentage values representing KPI metrics (conversion rate, churn rate, growth rate) are passed and returned as plain `float` values without a unit wrapper, e.g. `0.0734` representing 7.34%. The absence of a `%Percentage{value: float(), basis: :decimal | :percent}` type forces every display and comparison function to independently decide whether the value is in decimal or whole-percent form, producing implicit convention bugs. |

```elixir
defmodule Reporting.KPIDashboard do
  @moduledoc """
  Computes and formats key performance indicators for the executive
  dashboard. Covers conversion funnels, churn rates, growth metrics,
  and threshold-based alerting for the weekly business review.
  """

  require Logger

  alias Reporting.Repo
  alias Reporting.Schema.{FunnelEvent, Subscription, AlertRule}

  @alert_channels ~w(slack email pagerduty)

  # VALIDATION: SMELL START - Primitive Obsession
  # VALIDATION: This is a smell because percentage/rate values (conversion rate,
  # churn rate, growth rate) are plain `float` values like 0.0734 or 7.34,
  # with no indication whether the float is in decimal form (0–1) or
  # whole-percent form (0–100). A %Percentage{value: float(), scale: :decimal}
  # struct would make the scale explicit, prevent formatting bugs, and
  # centralise rounding and display logic.

  @spec compute_conversion_rate(integer(), integer()) ::
          {:ok, float()} | {:error, term()}
  def compute_conversion_rate(converted, total) when is_integer(converted) and is_integer(total) do
    cond do
      total <= 0 ->
        {:error, :zero_denominator}

      converted < 0 or converted > total ->
        {:error, {:invalid_conversion_counts, converted, total}}

      true ->
        rate = converted / total
        {:ok, Float.round(rate, 6)}
    end
  end

  @spec format_kpi_card(String.t(), float()) :: map()
  def format_kpi_card(metric_name, rate) when is_binary(metric_name) and is_float(rate) do
    display_value =
      rate
      |> Kernel.*(100.0)
      |> Float.round(2)
      |> then(&"#{&1}%")

    trend =
      cond do
        rate >= 0.10 -> :excellent
        rate >= 0.05 -> :good
        rate >= 0.02 -> :average
        true -> :poor
      end

    %{
      metric: metric_name,
      raw_rate: rate,
      display: display_value,
      trend: trend,
      updated_at: DateTime.utc_now()
    }
  end

  @spec threshold_alert(String.t(), float(), float()) :: :ok | {:error, :below_threshold}
  def threshold_alert(metric_name, current_rate, threshold_rate)
      when is_float(current_rate) and is_float(threshold_rate) do
    if current_rate >= threshold_rate do
      :ok
    else
      gap = Float.round((threshold_rate - current_rate) * 100.0, 2)

      Logger.warning(
        "KPI alert: #{metric_name} is #{Float.round(current_rate * 100.0, 2)}% " <>
          "(threshold #{Float.round(threshold_rate * 100.0, 2)}%, gap #{gap}pp)"
      )

      rules = Repo.all(from r in AlertRule, where: r.metric == ^metric_name and r.active == true)

      Enum.each(rules, fn rule ->
        if rule.channel in @alert_channels do
          dispatch_alert(rule.channel, metric_name, current_rate, threshold_rate)
        end
      end)

      {:error, :below_threshold}
    end
  end

  @spec aggregate_funnel(list(map())) :: map()
  def aggregate_funnel(funnel_steps) when is_list(funnel_steps) do
    funnel_steps
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce(%{steps: []}, fn [step_a, step_b], acc ->
      {:ok, step_rate} = compute_conversion_rate(step_b.count, step_a.count)

      step_result = %{
        from: step_a.name,
        to: step_b.name,
        rate: step_rate,
        drop_off: Float.round((1.0 - step_rate) * 100.0, 2)
      }

      Map.update!(acc, :steps, &(&1 ++ [step_result]))
    end)
    |> then(fn result ->
      overall_rate =
        case {List.first(funnel_steps), List.last(funnel_steps)} do
          {nil, _} -> 0.0
          {first, last} -> if first.count > 0, do: last.count / first.count, else: 0.0
        end

      Map.put(result, :overall_conversion, Float.round(overall_rate, 6))
    end)
  end

  # VALIDATION: SMELL END

  ## Private helpers

  defp dispatch_alert(channel, metric, current, threshold) do
    payload = %{
      metric: metric,
      current_pct: Float.round(current * 100, 2),
      threshold_pct: Float.round(threshold * 100, 2),
      fired_at: DateTime.utc_now()
    }

    Logger.info("Dispatching alert via #{channel}: #{inspect(payload)}")
  end
end
```
