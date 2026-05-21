# Annotated Example — Bad Code

## Metadata

- **Smell name:** Large code generation by macros
- **Expected smell location:** `defmacro report_metric/2` inside `MyApp.Reporting.MetricDSL`
- **Affected function(s):** `report_metric/2` macro
- **Short explanation:** The macro expands a full validation and registration pipeline — including type enumeration, aggregation strategy checks, formatter validation, deduplication guards, and struct construction — directly inside the `quote` block. In reporting modules that can define tens of metrics, the compiler is forced to expand this large block for each call, bloating the compiled output.

---

```elixir
defmodule MyApp.Reporting.MetricDSL do
  @moduledoc """
  DSL for declaring report metrics within a reporting module.

  Example:

      defmodule MyApp.Reporting.SalesReport do
        use MyApp.Reporting.MetricDSL

        report_metric :total_revenue,
          type: :currency,
          aggregation: :sum,
          formatter: &MyApp.Formatters.currency/1

        report_metric :order_count,
          type: :integer,
          aggregation: :count

        report_metric :avg_order_value,
          type: :currency,
          aggregation: :avg,
          formatter: &MyApp.Formatters.currency/1
      end
  """

  defmacro __using__(_opts) do
    quote do
      import MyApp.Reporting.MetricDSL, only: [report_metric: 2]
      Module.register_attribute(__MODULE__, :report_metrics, accumulate: true)
      @before_compile MyApp.Reporting.MetricDSL
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      def metrics, do: @report_metrics

      def metric_names do
        Enum.map(@report_metrics, & &1.name)
      end
    end
  end

  # VALIDATION: SMELL START - Large code generation by macros
  # VALIDATION: This is a smell because every call to report_metric/2 expands
  # VALIDATION: the entire inline body: atom checks, allowed-types enumeration,
  # VALIDATION: allowed-aggregations enumeration, formatter-arity checks,
  # VALIDATION: deduplication guards, and struct construction. A report module
  # VALIDATION: with 15 metrics would have 15 full expansions of this code
  # VALIDATION: compiled into it, instead of 15 lightweight delegations to a
  # VALIDATION: shared function.
  defmacro report_metric(name, opts) do
    quote do
      name = unquote(name)
      opts = unquote(opts)

      unless is_atom(name) do
        raise ArgumentError,
              "report_metric/2: metric name must be an atom, got #{inspect(name)}"
      end

      valid_types = [:integer, :float, :currency, :percentage, :duration_ms, :string]
      type = Keyword.get(opts, :type, :float)

      unless type in valid_types do
        raise ArgumentError,
              "report_metric/2: :type must be one of #{inspect(valid_types)}, " <>
                "got #{inspect(type)}"
      end

      valid_aggregations = [:sum, :count, :avg, :min, :max, :last, :first]
      aggregation = Keyword.get(opts, :aggregation, :sum)

      unless aggregation in valid_aggregations do
        raise ArgumentError,
              "report_metric/2: :aggregation must be one of #{inspect(valid_aggregations)}, " <>
                "got #{inspect(aggregation)}"
      end

      formatter = Keyword.get(opts, :formatter)

      if not is_nil(formatter) do
        unless is_function(formatter, 1) do
          raise ArgumentError,
                "report_metric/2: :formatter must be a 1-arity function if provided, " <>
                  "got #{inspect(formatter)}"
        end
      end

      label = Keyword.get(opts, :label, name |> Atom.to_string() |> String.replace("_", " "))

      unless is_binary(label) do
        raise ArgumentError,
              "report_metric/2: :label must be a string, got #{inspect(label)}"
      end

      existing = Module.get_attribute(__MODULE__, :report_metrics)

      if Enum.any?(existing, fn m -> m.name == name end) do
        raise ArgumentError,
              "report_metric/2: duplicate metric #{inspect(name)} in #{inspect(__MODULE__)}"
      end

      metric = %{
        name:        name,
        type:        type,
        aggregation: aggregation,
        formatter:   formatter,
        label:       label
      }

      @report_metrics metric
    end
  end
  # VALIDATION: SMELL END

  @doc """
  Computes a report by applying each registered metric's aggregation to
  the given dataset rows.
  """
  @spec compute(module(), [map()]) :: map()
  def compute(report_module, rows) do
    report_module.metrics()
    |> Enum.map(fn metric ->
      raw_value = aggregate(metric.aggregation, rows, metric.name)
      display   = apply_formatter(metric.formatter, raw_value)
      {metric.name, %{raw: raw_value, display: display, label: metric.label}}
    end)
    |> Map.new()
  end

  defp aggregate(:sum,   rows, field), do: Enum.sum(Enum.map(rows, &Map.get(&1, field, 0)))
  defp aggregate(:count, rows, _field), do: length(rows)
  defp aggregate(:avg,   rows, field) do
    total = Enum.sum(Enum.map(rows, &Map.get(&1, field, 0)))
    if length(rows) == 0, do: 0, else: total / length(rows)
  end
  defp aggregate(:min,   rows, field), do: Enum.min(Enum.map(rows, &Map.get(&1, field, 0)))
  defp aggregate(:max,   rows, field), do: Enum.max(Enum.map(rows, &Map.get(&1, field, 0)))
  defp aggregate(:last,  rows, field), do: rows |> List.last() |> Map.get(field)
  defp aggregate(:first, rows, field), do: rows |> List.first() |> Map.get(field)

  defp apply_formatter(nil,       value), do: to_string(value)
  defp apply_formatter(formatter, value), do: formatter.(value)
end
```
