```elixir
defmodule Analytics.Pipeline.EventProcessor do
  @moduledoc """
  Processes a stream of raw analytics events through a configurable
  transformation pipeline. Each stage is independently testable and
  composable via the `run/2` entry point.
  """

  alias Analytics.Pipeline.{Event, EnrichedEvent, ProcessingResult}

  @type stage :: (Event.t() -> {:ok, Event.t()} | {:error, term()})
  @type pipeline_opts :: [stages: [stage()], drop_invalid: boolean()]

  @doc """
  Runs a list of raw event maps through the processing pipeline.

  Accepts a keyword list of options:
  - `:stages` — ordered list of transformation functions (default: `default_stages/0`)
  - `:drop_invalid` — when `true`, silently drops events that fail validation (default: `false`)
  """
  @spec run([map()], pipeline_opts()) :: ProcessingResult.t()
  def run(raw_events, opts \\ []) when is_list(raw_events) do
    stages = Keyword.get(opts, :stages, default_stages())
    drop_invalid = Keyword.get(opts, :drop_invalid, false)

    raw_events
    |> Enum.map(&parse_raw_event/1)
    |> Enum.reduce(%ProcessingResult{}, fn parsed, acc ->
      process_one(parsed, stages, drop_invalid, acc)
    end)
  end

  # ---------------------------------------------------------------------------
  # Default pipeline stages
  # ---------------------------------------------------------------------------

  @doc false
  @spec default_stages() :: [stage()]
  def default_stages do
    [
      &validate_required_fields/1,
      &normalize_timestamps/1,
      &enrich_geo_data/1,
      &sanitize_user_agent/1
    ]
  end

  # ---------------------------------------------------------------------------
  # Private processing helpers
  # ---------------------------------------------------------------------------

  @spec process_one(
          {:ok, Event.t()} | {:error, term()},
          [stage()],
          boolean(),
          ProcessingResult.t()
        ) :: ProcessingResult.t()
  defp process_one({:error, reason}, _stages, true, acc) do
    %{acc | dropped: acc.dropped + 1, errors: [{:parse_error, reason} | acc.errors]}
  end

  defp process_one({:error, reason}, _stages, false, acc) do
    %{acc | failed: acc.failed + 1, errors: [{:parse_error, reason} | acc.errors]}
  end

  defp process_one({:ok, event}, stages, drop_invalid, acc) do
    case apply_stages(event, stages) do
      {:ok, enriched} ->
        %{acc | succeeded: acc.succeeded + 1, results: [enriched | acc.results]}

      {:error, reason} when drop_invalid ->
        %{acc | dropped: acc.dropped + 1, errors: [{:stage_error, reason} | acc.errors]}

      {:error, reason} ->
        %{acc | failed: acc.failed + 1, errors: [{:stage_error, reason} | acc.errors]}
    end
  end

  @spec apply_stages(Event.t(), [stage()]) :: {:ok, EnrichedEvent.t()} | {:error, term()}
  defp apply_stages(event, stages) do
    Enum.reduce_while(stages, {:ok, event}, fn stage, {:ok, current} ->
      case stage.(current) do
        {:ok, updated} -> {:cont, {:ok, updated}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  @spec parse_raw_event(map()) :: {:ok, Event.t()} | {:error, :missing_event_type}
  defp parse_raw_event(%{"type" => type, "timestamp" => ts, "payload" => payload}) do
    {:ok, %Event{type: type, timestamp: ts, payload: payload}}
  end

  defp parse_raw_event(_), do: {:error, :missing_event_type}

  @spec validate_required_fields(Event.t()) :: {:ok, Event.t()} | {:error, :invalid_payload}
  defp validate_required_fields(%Event{payload: payload} = event) when is_map(payload) do
    {:ok, event}
  end

  defp validate_required_fields(_), do: {:error, :invalid_payload}

  @spec normalize_timestamps(Event.t()) :: {:ok, Event.t()} | {:error, :invalid_timestamp}
  defp normalize_timestamps(%Event{timestamp: ts} = event) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> {:ok, %{event | timestamp: dt}}
      {:error, _} -> {:error, :invalid_timestamp}
    end
  end

  defp normalize_timestamps(%Event{timestamp: %DateTime{}} = event), do: {:ok, event}
  defp normalize_timestamps(_), do: {:error, :invalid_timestamp}

  @spec enrich_geo_data(Event.t()) :: {:ok, Event.t()}
  defp enrich_geo_data(%Event{payload: payload} = event) do
    enriched_payload = Map.put_new(payload, "geo", %{"region" => "unknown"})
    {:ok, %{event | payload: enriched_payload}}
  end

  @spec sanitize_user_agent(Event.t()) :: {:ok, Event.t()}
  defp sanitize_user_agent(%Event{payload: payload} = event) do
    sanitized =
      Map.update(payload, "user_agent", "unknown", fn ua ->
        if is_binary(ua), do: String.slice(ua, 0, 256), else: "unknown"
      end)

    {:ok, %{event | payload: sanitized}}
  end
end
```
