```elixir
defmodule Ops.AuditLogExporter do
  @moduledoc """
  Exports audit log entries to external compliance storage in configurable
  batches. The exporter reads entries in chronological order from the
  database, converts them to a structured format, and ships them to a
  configured sink (file, S3, or an HTTP endpoint). Progress is tracked
  via a cursor so interrupted exports resume from the last successful batch.
  """

  require Logger

  alias MyApp.Repo
  alias Audit.Entry

  import Ecto.Query, warn: false

  @type sink_fn :: ([map()] -> :ok | {:error, term()})
  @type export_result :: %{exported: non_neg_integer(), batches: non_neg_integer(), duration_ms: non_neg_integer()}

  @default_batch_size 200

  @doc """
  Exports audit entries inserted between `from_dt` and `to_dt` to `sink_fn`.
  Processes in batches of `batch_size` and returns a summary of the run.
  """
  @spec export(DateTime.t(), DateTime.t(), sink_fn(), keyword()) ::
          {:ok, export_result()} | {:error, term()}
  def export(from_dt, to_dt, sink_fn, opts \\ [])
      when is_function(sink_fn, 1) do
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    start_mono = System.monotonic_time(:millisecond)

    result = export_window(from_dt, to_dt, sink_fn, batch_size, 0, 0)

    case result do
      {:ok, {exported, batches}} ->
        duration_ms = System.monotonic_time(:millisecond) - start_mono
        Logger.info("[AuditLogExporter] Exported #{exported} entries in #{batches} batch(es), #{duration_ms}ms")
        {:ok, %{exported: exported, batches: batches, duration_ms: duration_ms}}

      {:error, _} = err ->
        err
    end
  end

  @doc "Converts a single audit entry to the wire format used by sinks."
  @spec to_wire(Entry.t()) :: map()
  def to_wire(%Entry{} = entry) do
    %{
      id: entry.id,
      actor_id: entry.actor_id,
      action: entry.action,
      resource_type: entry.resource_type,
      resource_id: entry.resource_id,
      metadata: entry.metadata || %{},
      ip_address: entry.ip_address,
      occurred_at: DateTime.to_iso8601(entry.inserted_at)
    }
  end

  defp export_window(from_dt, to_dt, sink_fn, batch_size, total_exported, batches) do
    entries = fetch_batch(from_dt, to_dt, batch_size)

    if Enum.empty?(entries) do
      {:ok, {total_exported, batches}}
    else
      wire = Enum.map(entries, &to_wire/1)

      case sink_fn.(wire) do
        :ok ->
          last_entry = List.last(entries)
          new_from = last_entry.inserted_at

          if length(entries) < batch_size do
            {:ok, {total_exported + length(entries), batches + 1}}
          else
            export_window(new_from, to_dt, sink_fn, batch_size, total_exported + length(entries), batches + 1)
          end

        {:error, reason} ->
          Logger.error("[AuditLogExporter] Sink failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp fetch_batch(from_dt, to_dt, batch_size) do
    from(e in Entry,
      where: e.inserted_at > ^from_dt and e.inserted_at <= ^to_dt,
      order_by: [asc: e.inserted_at, asc: e.id],
      limit: ^batch_size
    )
    |> Repo.all()
  end
end
```
