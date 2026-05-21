```elixir
defmodule Telemetry.MetricsDSL do
  @moduledoc """
  Compile-time DSL for declaring application metrics exposed via Telemetry.

  Metrics are registered with their event names, measurement keys, units,
  and tag sets. The registry is consumed at startup to initialise the
  reporter pipeline.
  """

  @valid_types    [:counter, :summary, :last_value, :distribution]
  @valid_units    [:unit, :millisecond, :microsecond, :byte, :kilobyte, :megabyte]

  defmacro defmetric(metric_name, opts) do
    quote do
      metric = unquote(metric_name)
      opts   = unquote(opts)

      unless is_atom(metric) do
        raise ArgumentError,
              "metric name must be an atom, got: #{inspect(metric)}"
      end

      type = Keyword.fetch!(opts, :type)

      unless type in unquote(@valid_types) do
        raise ArgumentError,
              "metric #{inspect(metric)} :type must be one of #{inspect(unquote(@valid_types))}"
      end

      event_name = Keyword.fetch!(opts, :event_name)

      unless is_list(event_name) and event_name != [] do
        raise ArgumentError,
              "metric #{inspect(metric)} :event_name must be a non-empty list"
      end

      Enum.each(event_name, fn segment ->
        unless is_atom(segment) do
          raise ArgumentError,
                "metric #{inspect(metric)} :event_name segments must be atoms, got: #{inspect(segment)}"
        end
      end)

      measurement = Keyword.fetch!(opts, :measurement)

      unless is_atom(measurement) do
        raise ArgumentError,
              "metric #{inspect(metric)} :measurement must be an atom"
      end

      unit = Keyword.get(opts, :unit, :unit)

      unless unit in unquote(@valid_units) do
        raise ArgumentError,
              "metric #{inspect(metric)} :unit must be one of #{inspect(unquote(@valid_units))}"
      end

      tags = Keyword.get(opts, :tags, [])

      unless is_list(tags) and Enum.all?(tags, &is_atom/1) do
        raise ArgumentError,
              "metric #{inspect(metric)} :tags must be a list of atoms"
      end

      buckets = Keyword.get(opts, :buckets)

      if buckets != nil do
        unless type == :distribution do
          raise ArgumentError,
                "metric #{inspect(metric)} :buckets can only be set for :distribution metrics"
        end

        unless is_list(buckets) and Enum.all?(buckets, &is_number/1) do
          raise ArgumentError,
                "metric #{inspect(metric)} :buckets must be a list of numbers"
        end
      end

      @telemetry_metrics %{
        name:        metric,
        type:        type,
        event_name:  event_name,
        measurement: measurement,
        unit:        unit,
        tags:        tags,
        buckets:     buckets
      }
    end
  end

  defmacro __using__(_) do
    quote do
      import Telemetry.MetricsDSL, only: [defmetric: 2]
      Module.register_attribute(__MODULE__, :telemetry_metrics, accumulate: true)
      @before_compile Telemetry.MetricsDSL
    end
  end

  defmacro __before_compile__(env) do
    metrics = Module.get_attribute(env.module, :telemetry_metrics)

    quote do
      def metrics, do: unquote(Macro.escape(metrics))

      def metric(name) do
        Enum.find(metrics(), &(&1.name == name))
      end

      def metrics_of_type(type) do
        Enum.filter(metrics(), &(&1.type == type))
      end
    end
  end
end

defmodule Telemetry.AppMetrics do
  use Telemetry.MetricsDSL

  defmetric(:http_request_count,
    type: :counter,
    event_name: [:phoenix, :endpoint, :stop],
    measurement: :duration,
    unit: :millisecond,
    tags: [:method, :route, :status]
  )

  defmetric(:http_request_duration,
    type: :distribution,
    event_name: [:phoenix, :endpoint, :stop],
    measurement: :duration,
    unit: :millisecond,
    tags: [:method, :route],
    buckets: [10, 50, 100, 250, 500, 1_000, 2_500, 5_000]
  )

  defmetric(:db_query_duration,
    type: :distribution,
    event_name: [:myapp, :repo, :query],
    measurement: :query_time,
    unit: :microsecond,
    tags: [:source],
    buckets: [100, 500, 1_000, 5_000, 10_000]
  )

  defmetric(:payment_capture_count,
    type: :counter,
    event_name: [:myapp, :payments, :capture],
    measurement: :count,
    unit: :unit,
    tags: [:gateway, :status]
  )

  defmetric(:job_queue_latency,
    type: :distribution,
    event_name: [:oban, :job, :start],
    measurement: :queue_time,
    unit: :millisecond,
    tags: [:queue, :worker],
    buckets: [50, 200, 500, 1_000, 5_000, 30_000]
  )

  defmetric(:cache_hit_count,
    type: :counter,
    event_name: [:myapp, :cache, :hit],
    measurement: :count,
    unit: :unit,
    tags: [:cache_name]
  )

  defmetric(:active_sessions,
    type: :last_value,
    event_name: [:myapp, :sessions, :count],
    measurement: :total,
    unit: :unit,
    tags: []
  )
end
```
