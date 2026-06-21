```elixir
defmodule Analytics.EventPipeline do
  @moduledoc """
  A stream-based ETL pipeline for transforming raw event records into enriched
  analytics entries and persisting them in configurable batches.

  The pipeline is stateless and composable; each stage is a pure function.
  """

  alias Analytics.EventPipeline.{Transformer, Loader}

  @type raw_event :: map()
  @type enriched_event :: map()
  @type run_opts :: [batch_size: pos_integer(), concurrency: pos_integer()]
  @type run_result :: {:ok, non_neg_integer()} | {:error, term()}

  @doc """
  Runs the full pipeline over a stream of raw events.

  Returns `{:ok, persisted_count}` or `{:error, reason}` if the stream
  cannot be opened.
  """
  @spec run(Enumerable.t(), run_opts()) :: run_result()
  def run(source_stream, opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, 100)
    concurrency = Keyword.get(opts, :concurrency, System.schedulers_online())

    count =
      source_stream
      |> Stream.map(&Transformer.normalize/1)
      |> Stream.filter(&Transformer.valid?/1)
      |> Stream.map(&Transformer.enrich/1)
      |> Stream.chunk_every(batch_size)
      |> Task.async_stream(&Loader.persist_batch/1,
        max_concurrency: concurrency,
        timeout: 30_000,
        on_timeout: :kill_task
      )
      |> Stream.flat_map(&extract_count/1)
      |> Enum.sum()

    {:ok, count}
  end

  defp extract_count({:ok, n}) when is_integer(n) and n >= 0, do: [n]
  defp extract_count(_), do: [0]
end

defmodule Analytics.EventPipeline.Transformer do
  @moduledoc """
  Stateless functions for normalizing and enriching raw event maps.
  """

  @type raw_event :: map()
  @type enriched_event :: map()

  @doc "Returns true if a normalized event has the required fields."
  @spec valid?(map()) :: boolean()
  def valid?(%{type: type, timestamp: ts}) when is_binary(type) and not is_nil(ts), do: true
  def valid?(_), do: false

  @doc "Coerces string keys and parses timestamps from a raw event map."
  @spec normalize(raw_event()) :: map()
  def normalize(%{"type" => type, "timestamp" => ts} = raw) do
    raw
    |> Map.put(:type, type)
    |> Map.put(:timestamp, parse_timestamp(ts))
    |> Map.put(:received_at, DateTime.utc_now())
    |> Map.drop(["type", "timestamp"])
  end

  def normalize(raw) when is_map(raw), do: raw

  @doc "Adds computed metadata fields to a valid normalized event."
  @spec enrich(enriched_event()) :: enriched_event()
  def enrich(%{type: type} = event) when is_binary(type) do
    event
    |> Map.put(:category, categorize(type))
    |> Map.put(:pipeline_version, 2)
  end

  def enrich(event), do: event

  defp categorize("page_" <> _), do: :pageview
  defp categorize("click_" <> _), do: :interaction
  defp categorize("error_" <> _), do: :error
  defp categorize(_), do: :other

  defp parse_timestamp(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_timestamp(_), do: nil
end

defmodule Analytics.EventPipeline.Loader do
  @moduledoc """
  Persists batches of enriched events using the analytics Repo.
  """

  alias Analytics.Repo
  alias Analytics.Event

  @doc "Inserts a batch of enriched events. Returns the count inserted."
  @spec persist_batch([map()]) :: non_neg_integer()
  def persist_batch(events) when is_list(events) do
    records = Enum.map(events, &to_record/1)
    {count, _} = Repo.insert_all(Event, records, on_conflict: :nothing)
    count
  end

  defp to_record(event) when is_map(event) do
    event
    |> Map.take([:type, :category, :timestamp, :received_at, :pipeline_version])
    |> Map.put(:inserted_at, DateTime.utc_now())
  end
end
```
