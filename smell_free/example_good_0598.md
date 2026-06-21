```elixir
defmodule Ingestion.LogPipeline do
  @moduledoc """
  Processes a continuous stream of raw JSON log lines from multiple sources.
  Each log line is parsed, enriched with geo-IP and service metadata,
  filtered for noise, and forwarded to the storage writer. The pipeline is
  fully lazy using `Stream` so memory usage stays constant regardless of
  throughput. Errors in individual lines are counted and surfaced in the
  result summary without aborting the rest of the batch.
  """

  alias Ingestion.{GeoEnricher, Parser, ServiceRegistry, Writer}

  @type log_source :: Enumerable.t()
  @type pipeline_result :: %{
          processed: non_neg_integer(),
          written: non_neg_integer(),
          parse_errors: non_neg_integer(),
          filtered: non_neg_integer()
        }

  @doc """
  Processes all log lines from `source` through the full enrichment and
  filtering pipeline. Returns a result summary map. The source may be any
  `Enumerable`, including `File.stream!/1` for file ingestion or a
  socket-backed stream for live tail processing.
  """
  @spec run(log_source()) :: pipeline_result()
  def run(source) do
    source
    |> Stream.map(&parse_line/1)
    |> Stream.map(&enrich_geo/1)
    |> Stream.map(&enrich_service/1)
    |> Stream.reject(&noise?/1)
    |> Stream.chunk_every(500)
    |> Enum.reduce(empty_result(), &process_chunk/2)
  end

  # ---------------------------------------------------------------------------
  # Pipeline stages
  # ---------------------------------------------------------------------------

  defp parse_line(raw) when is_binary(raw) do
    case Jason.decode(String.trim(raw)) do
      {:ok, map} ->
        {:ok, normalise(map)}

      {:error, _} ->
        {:parse_error, raw}
    end
  end

  defp enrich_geo({:ok, entry}) do
    case GeoEnricher.lookup(Map.get(entry, "client_ip")) do
      {:ok, geo} -> {:ok, Map.put(entry, "geo", geo)}
      _ -> {:ok, entry}
    end
  end

  defp enrich_geo(error), do: error

  defp enrich_service({:ok, entry}) do
    service_name = Map.get(entry, "service")

    case ServiceRegistry.metadata(service_name) do
      {:ok, meta} -> {:ok, Map.put(entry, "service_meta", meta)}
      _ -> {:ok, entry}
    end
  end

  defp enrich_service(error), do: error

  defp noise?({:parse_error, _}), do: false
  defp noise?({:ok, entry}) do
    health_check?(entry) or ignored_user_agent?(entry) or low_severity?(entry)
  end

  defp process_chunk(chunk, acc) do
    {to_write, errors, filtered} =
      Enum.reduce(chunk, {[], 0, 0}, fn
        {:ok, entry}, {entries, errs, filt} -> {[entry | entries], errs, filt}
        {:parse_error, _raw}, {entries, errs, filt} -> {entries, errs + 1, filt}
        :filtered, {entries, errs, filt} -> {entries, errs, filt + 1}
      end)

    written =
      case Writer.write_batch(Enum.reverse(to_write)) do
        {:ok, count} -> count
        {:error, reason} ->
          require Logger
          Logger.error("Log batch write failed", reason: inspect(reason), batch_size: length(to_write))
          0
      end

    %{
      processed: acc.processed + length(chunk),
      written: acc.written + written,
      parse_errors: acc.parse_errors + errors,
      filtered: acc.filtered + filtered
    }
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp normalise(map) do
    %{
      "timestamp" => Map.get(map, "timestamp") || Map.get(map, "ts") || Map.get(map, "@timestamp"),
      "level" => Map.get(map, "level", "info") |> String.downcase(),
      "message" => Map.get(map, "message") || Map.get(map, "msg"),
      "service" => Map.get(map, "service"),
      "client_ip" => Map.get(map, "client_ip") || Map.get(map, "remote_addr"),
      "user_agent" => Map.get(map, "user_agent"),
      "raw" => map
    }
  end

  defp health_check?(%{"message" => msg}) when is_binary(msg) do
    String.contains?(msg, "/health") or String.contains?(msg, "/ping")
  end

  defp health_check?(_), do: false

  defp ignored_user_agent?(%{"user_agent" => ua}) when is_binary(ua) do
    String.contains?(ua, "kube-probe") or String.contains?(ua, "ELB-HealthChecker")
  end

  defp ignored_user_agent?(_), do: false

  defp low_severity?(%{"level" => level}), do: level in ["trace", "debug"]
  defp low_severity?(_), do: false

  defp empty_result, do: %{processed: 0, written: 0, parse_errors: 0, filtered: 0}
end
```
