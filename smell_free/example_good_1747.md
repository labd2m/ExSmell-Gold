```elixir
defmodule Telemetry.MetricsPipeline do
  @moduledoc """
  Ingests raw telemetry events, applies enrichment and filtering rules,
  and forwards processed metrics to configured sink adapters.
  """

  alias Telemetry.{Event, SinkRegistry, Enricher, Filter}

  @type raw_event :: %{name: [atom()], measurements: map(), metadata: map()}
  @type processed_event :: %{
    name: String.t(),
    measurements: map(),
    metadata: map(),
    tags: map(),
    received_at: DateTime.t()
  }
  @type sink_name :: atom()
  @type pipeline_result :: {:ok, [sink_name()]} | {:error, String.t()}

  @spec ingest(raw_event()) :: pipeline_result()
  def ingest(%{name: name, measurements: measurements, metadata: metadata} = _event)
      when is_list(name) and is_map(measurements) and is_map(metadata) do
    with {:ok, parsed} <- parse_event(name, measurements, metadata),
         {:ok, enriched} <- Enricher.enrich(parsed),
         :ok <- validate_measurements(enriched) do
      if Filter.should_drop?(enriched) do
        {:ok, []}
      else
        forward_to_sinks(enriched)
      end
    end
  end

  @spec ingest_batch([raw_event()]) :: %{ok: non_neg_integer(), dropped: non_neg_integer(), errors: [String.t()]}
  def ingest_batch(events) when is_list(events) do
    Enum.reduce(events, %{ok: 0, dropped: 0, errors: []}, fn event, acc ->
      case ingest(event) do
        {:ok, []} -> %{acc | dropped: acc.dropped + 1}
        {:ok, _sinks} -> %{acc | ok: acc.ok + 1}
        {:error, reason} -> %{acc | errors: [reason | acc.errors]}
      end
    end)
  end

  @spec parse_event([atom()], map(), map()) :: {:ok, processed_event()} | {:error, String.t()}
  defp parse_event(name, measurements, metadata) do
    event_name = name |> Enum.map(&Atom.to_string/1) |> Enum.join(".")

    {:ok, %{
      name: event_name,
      measurements: measurements,
      metadata: metadata,
      tags: extract_tags(metadata),
      received_at: DateTime.utc_now()
    }}
  end

  @spec validate_measurements(processed_event()) :: :ok | {:error, String.t()}
  defp validate_measurements(%{measurements: measurements, name: name}) do
    if map_size(measurements) == 0 do
      {:error, "Event '#{name}' has no measurements"}
    else
      invalid = Enum.find(measurements, fn {_, v} -> not is_number(v) end)

      if invalid do
        {key, _} = invalid
        {:error, "Measurement '#{key}' in event '#{name}' is not a number"}
      else
        :ok
      end
    end
  end

  @spec forward_to_sinks(processed_event()) :: {:ok, [sink_name()]} | {:error, String.t()}
  defp forward_to_sinks(event) do
    sinks = SinkRegistry.matching_sinks(event.name)

    if Enum.empty?(sinks) do
      {:ok, []}
    else
      delivered = Enum.flat_map(sinks, &deliver_to_sink(&1, event))
      {:ok, delivered}
    end
  end

  @spec deliver_to_sink(sink_name(), processed_event()) :: [sink_name()]
  defp deliver_to_sink(sink_name, event) do
    case SinkRegistry.send(sink_name, event) do
      :ok -> [sink_name]
      {:error, _reason} -> []
    end
  end

  @spec extract_tags(map()) :: map()
  defp extract_tags(metadata) do
    metadata
    |> Map.take([:service, :host, :environment, :version, :region])
    |> Map.new(fn {k, v} -> {Atom.to_string(k), to_string(v)} end)
  end
end

defmodule Telemetry.Filter do
  @moduledoc """
  Determines whether a processed telemetry event should be dropped
  based on configurable name prefix exclusion rules.
  """

  @drop_prefixes Application.compile_env(:my_app, :telemetry_drop_prefixes, [])

  @spec should_drop?(Telemetry.MetricsPipeline.processed_event()) :: boolean()
  def should_drop?(%{name: name}) when is_binary(name) do
    Enum.any?(@drop_prefixes, &String.starts_with?(name, &1))
  end

  @spec register_drop_prefix(String.t()) :: :ok
  def register_drop_prefix(prefix) when is_binary(prefix) do
    current = Application.get_env(:my_app, :telemetry_drop_prefixes, [])
    Application.put_env(:my_app, :telemetry_drop_prefixes, [prefix | current])
    :ok
  end
end
```
