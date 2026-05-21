# Annotated Example — Bad Code

## Metadata

- **Smell name:** Large code generation by macros
- **Expected smell location:** `defmacro telemetry_counter/2` inside `MyApp.Telemetry.MetricsDSL`
- **Affected function(s):** `telemetry_counter/2` macro
- **Short explanation:** Every call to `telemetry_counter/2` expands a large `quote` block performing event-name list validation, unit checking, tag extraction, reporter module validation, description string checks, deduplication guards, and struct registration at the call site. A telemetry module defining many metrics will have all of this code compiled repeatedly, once per declaration.

---

```elixir
defmodule MyApp.Telemetry.MetricsDSL do
  @moduledoc """
  DSL for declaring telemetry metrics within a metrics module.

  Example:

      defmodule MyApp.Telemetry.AppMetrics do
        use MyApp.Telemetry.MetricsDSL

        telemetry_counter [:http, :request, :stop],
          tags:        [:method, :route, :status],
          description: "Total HTTP requests",
          reporter:    MyApp.Telemetry.StatsD

        telemetry_counter [:db, :query, :stop],
          tags:        [:source, :command],
          unit:        :millisecond,
          description: "Total DB queries",
          reporter:    MyApp.Telemetry.StatsD

        telemetry_counter [:payments, :charge, :success],
          tags:        [:gateway, :currency],
          description: "Successful payment charges"
      end
  """

  defmacro __using__(_opts) do
    quote do
      import MyApp.Telemetry.MetricsDSL, only: [telemetry_counter: 2]
      Module.register_attribute(__MODULE__, :metrics, accumulate: true)
      @before_compile MyApp.Telemetry.MetricsDSL
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      def metrics, do: @metrics

      def attach_all do
        MyApp.Telemetry.MetricsDSL.attach_metrics(__MODULE__.metrics())
      end
    end
  end

  # VALIDATION: SMELL START - Large code generation by macros
  # VALIDATION: This is a smell because each call to telemetry_counter/2 causes
  # VALIDATION: the compiler to expand this entire block at the call site:
  # VALIDATION: event-name list-of-atoms check, tags list check, unit enum
  # VALIDATION: check, reporter module compilation and callback check,
  # VALIDATION: description string check, deduplication guard, and metric
  # VALIDATION: struct registration. A metrics module with dozens of counters
  # VALIDATION: compiles all of this code once per counter rather than once
  # VALIDATION: inside a shared function.
  defmacro telemetry_counter(event_name, opts) do
    quote do
      event_name = unquote(event_name)
      opts       = unquote(opts)

      unless is_list(event_name) and Enum.all?(event_name, &is_atom/1) do
        raise ArgumentError,
              "telemetry_counter/2: event_name must be a list of atoms, " <>
                "got #{inspect(event_name)}"
      end

      if Enum.empty?(event_name) do
        raise ArgumentError,
              "telemetry_counter/2: event_name must not be empty"
      end

      tags = Keyword.get(opts, :tags, [])

      unless is_list(tags) and Enum.all?(tags, &is_atom/1) do
        raise ArgumentError,
              "telemetry_counter/2: :tags must be a list of atoms, got #{inspect(tags)}"
      end

      valid_units = [:unit, :byte, :kilobyte, :megabyte, :millisecond, :second, :microsecond]
      unit = Keyword.get(opts, :unit, :unit)

      unless unit in valid_units do
        raise ArgumentError,
              "telemetry_counter/2: :unit must be one of #{inspect(valid_units)}, " <>
                "got #{inspect(unit)}"
      end

      reporter = Keyword.get(opts, :reporter)

      if not is_nil(reporter) do
        unless is_atom(reporter) do
          raise ArgumentError,
                "telemetry_counter/2: :reporter must be a module atom, got #{inspect(reporter)}"
        end

        :ok = Code.ensure_compiled!(reporter)

        unless function_exported?(reporter, :handle_metric, 2) do
          raise ArgumentError,
                "telemetry_counter/2: reporter #{inspect(reporter)} must export handle_metric/2"
        end
      end

      description = Keyword.get(opts, :description, "")

      unless is_binary(description) do
        raise ArgumentError,
              "telemetry_counter/2: :description must be a string, got #{inspect(description)}"
      end

      existing = Module.get_attribute(__MODULE__, :metrics)

      if Enum.any?(existing, fn m -> m.event_name == event_name end) do
        raise ArgumentError,
              "telemetry_counter/2: duplicate metric for event #{inspect(event_name)} " <>
                "in #{inspect(__MODULE__)}"
      end

      metric = %{
        type:        :counter,
        event_name:  event_name,
        tags:        tags,
        unit:        unit,
        reporter:    reporter,
        description: description
      }

      @metrics metric
    end
  end
  # VALIDATION: SMELL END

  @doc false
  def attach_metrics(metrics) do
    Enum.each(metrics, fn metric ->
      handler_id = {__MODULE__, metric.event_name}

      :telemetry.attach(
        handler_id,
        metric.event_name,
        &handle_event/4,
        %{metric: metric}
      )
    end)
  end

  defp handle_event(event, measurements, metadata, %{metric: metric}) do
    if metric.reporter do
      metric.reporter.handle_metric(
        %{event: event, measurements: measurements, metadata: metadata},
        metric
      )
    end
  end
end
```
