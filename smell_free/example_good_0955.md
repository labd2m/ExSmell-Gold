```elixir
defmodule Telemetry.PrometheusExporter do
  @moduledoc """
  Exposes collected application metrics in Prometheus text format for
  scraping. Each metric family is built from telemetry event measurements
  stored in ETS. The exporter formats counters, gauges, and histograms
  following the Prometheus exposition format specification. Output is
  generated on demand with no background process required.
  """

  @table :prometheus_metrics
  @text_content_type "text/plain; version=0.0.4; charset=utf-8"

  @type metric_type :: :counter | :gauge | :histogram
  @type label_set :: %{String.t() => String.t()}
  @type metric_entry :: %{
          name: String.t(),
          type: metric_type(),
          help: String.t(),
          value: number(),
          labels: label_set(),
          updated_at: integer()
        }

  @doc "Initialises the metrics ETS table. Call once at application startup."
  @spec init() :: :ok
  def init do
    :ets.new(@table, [:set, :public, :named_table, write_concurrency: true])
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Records or updates a metric value. Thread-safe via ETS."
  @spec record(String.t(), metric_type(), String.t(), number(), label_set()) :: :ok
  def record(name, type, help, value, labels \\ %{})
      when is_binary(name) and is_atom(type) and is_number(value) do
    key = {name, labels}
    entry = %{name: name, type: type, help: help, value: value,
              labels: labels, updated_at: System.monotonic_time(:millisecond)}
    :ets.insert(@table, {key, entry})
    :ok
  end

  @doc "Increments a counter metric by `amount`."
  @spec increment(String.t(), String.t(), number(), label_set()) :: :ok
  def increment(name, help, amount \\ 1, labels \\ %{}) when is_number(amount) do
    key = {name, labels}
    case :ets.lookup(@table, key) do
      [{^key, entry}] ->
        :ets.insert(@table, {key, %{entry | value: entry.value + amount}})
      [] ->
        record(name, :counter, help, amount, labels)
    end
    :ok
  end

  @doc "Renders all recorded metrics to a Prometheus-compatible text string."
  @spec render() :: String.t()
  def render do
    :ets.tab2list(@table)
    |> Enum.map(fn {_key, entry} -> entry end)
    |> Enum.group_by(& &1.name)
    |> Enum.map_join("\n", fn {name, entries} ->
      first = List.first(entries)
      header = "# HELP #{name} #{first.help}\n# TYPE #{name} #{first.type}"
      lines = Enum.map(entries, &format_line/1)
      Enum.join([header | lines], "\n")
    end)
    |> then(&"#{&1}\n")
  end

  @doc "Returns the Prometheus content type header value."
  @spec content_type() :: String.t()
  def content_type, do: @text_content_type

  defp format_line(%{name: name, value: value, labels: labels}) do
    if map_size(labels) == 0 do
      "#{name} #{value}"
    else
      label_str = labels |> Enum.map(fn {k, v} -> ~s(#{k}="#{v}") end) |> Enum.join(",")
      "#{name}{#{label_str}} #{value}"
    end
  end
end
```
