```elixir
defmodule Observability.Alerts.RuleEvaluator do
  @moduledoc """
  Evaluates time-series metric samples against a set of alert rules.
  Rules express threshold conditions; breaches produce structured alert events.
  Evaluation is stateless and pure; all state is passed explicitly.
  """

  @type metric_sample :: %{
          name: String.t(),
          value: number(),
          labels: %{String.t() => String.t()},
          timestamp: integer()
        }

  @type condition :: :gt | :gte | :lt | :lte | :eq | :neq
  @type severity :: :critical | :warning | :info

  @type rule :: %{
          id: String.t(),
          metric_name: String.t(),
          condition: condition(),
          threshold: number(),
          severity: severity(),
          label_matchers: %{String.t() => String.t()}
        }

  @type alert_event :: %{
          rule_id: String.t(),
          metric_name: String.t(),
          severity: severity(),
          value: number(),
          threshold: number(),
          labels: %{String.t() => String.t()},
          fired_at: integer()
        }

  @doc """
  Evaluates all `rules` against `samples` and returns fired alert events.
  Each sample is evaluated against every rule with a matching metric name.
  """
  @spec evaluate([rule()], [metric_sample()]) :: {:ok, [alert_event()]} | {:error, String.t()}
  def evaluate(rules, samples) when is_list(rules) and is_list(samples) do
    with :ok <- validate_rules(rules) do
      events =
        for sample <- samples,
            rule <- rules,
            rule.metric_name == sample.name,
            labels_match?(rule.label_matchers, sample.labels),
            condition_breached?(rule.condition, sample.value, rule.threshold) do
          build_alert_event(rule, sample)
        end

      {:ok, events}
    end
  end

  @doc """
  Returns rules whose severity matches one of the given levels.
  """
  @spec filter_by_severity([rule()], [severity()]) :: [rule()]
  def filter_by_severity(rules, severities) when is_list(rules) and is_list(severities) do
    Enum.filter(rules, fn r -> r.severity in severities end)
  end

  defp labels_match?(matchers, sample_labels) when map_size(matchers) == 0, do: true

  defp labels_match?(matchers, sample_labels) do
    Enum.all?(matchers, fn {k, v} -> Map.get(sample_labels, k) == v end)
  end

  defp condition_breached?(:gt, value, threshold), do: value > threshold
  defp condition_breached?(:gte, value, threshold), do: value >= threshold
  defp condition_breached?(:lt, value, threshold), do: value < threshold
  defp condition_breached?(:lte, value, threshold), do: value <= threshold
  defp condition_breached?(:eq, value, threshold), do: value == threshold
  defp condition_breached?(:neq, value, threshold), do: value != threshold

  defp build_alert_event(rule, sample) do
    %{
      rule_id: rule.id,
      metric_name: rule.metric_name,
      severity: rule.severity,
      value: sample.value,
      threshold: rule.threshold,
      labels: sample.labels,
      fired_at: sample.timestamp
    }
  end

  defp validate_rules(rules) do
    invalid = Enum.find(rules, fn r -> not valid_rule?(r) end)

    if is_nil(invalid) do
      :ok
    else
      {:error, "invalid rule shape: #{inspect(invalid)}"}
    end
  end

  @valid_conditions ~w(gt gte lt lte eq neq)a
  @valid_severities ~w(critical warning info)a

  defp valid_rule?(%{
         id: id,
         metric_name: mn,
         condition: c,
         threshold: t,
         severity: s,
         label_matchers: lm
       })
       when is_binary(id) and id != "" and
              is_binary(mn) and mn != "" and
              c in @valid_conditions and
              is_number(t) and
              s in @valid_severities and
              is_map(lm),
       do: true

  defp valid_rule?(_), do: false
end
```
