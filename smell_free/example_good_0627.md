```elixir
defmodule Catalogue.ImportPipeline do
  @moduledoc """
  Imports product catalogue data from a structured JSON feed. The pipeline
  validates each record, maps it to internal schema shapes, and upserts it
  to the database. Invalid records are collected and returned for operator
  review without aborting the entire import run. Progress is reported via
  telemetry events so dashboards can track long-running imports.
  """

  require Logger

  alias MyApp.Repo
  alias Store.Catalog.Product

  @type import_record :: map()
  @type import_result :: %{
          total: non_neg_integer(),
          upserted: non_neg_integer(),
          invalid: [%{record: import_record(), errors: [String.t()]}],
          duration_ms: non_neg_integer()
        }

  @required_fields ~w(sku name price_cents currency)
  @batch_size 100
  @telemetry_event [:catalogue, :import, :progress]

  @doc """
  Imports `records` into the catalogue. Processes in batches of #{@batch_size}
  and emits telemetry progress events. Returns a summary of the run.
  """
  @spec run([import_record()]) :: import_result()
  def run(records) when is_list(records) do
    start_mono = System.monotonic_time(:millisecond)
    total = length(records)

    {upserted, invalid} =
      records
      |> Enum.chunk_every(@batch_size)
      |> Enum.with_index(1)
      |> Enum.reduce({0, []}, fn {batch, batch_num}, {upsert_acc, invalid_acc} ->
        {ok_rows, bad_rows} = validate_batch(batch)
        upsert_count = upsert_batch(ok_rows)
        emit_progress(batch_num, length(batch), total)
        {upsert_acc + upsert_count, invalid_acc ++ bad_rows}
      end)

    duration_ms = System.monotonic_time(:millisecond) - start_mono

    Logger.info(
      "[CatalogueImport] Finished: #{upserted} upserted, #{length(invalid)} invalid, #{duration_ms}ms"
    )

    %{total: total, upserted: upserted, invalid: invalid, duration_ms: duration_ms}
  end

  @doc "Validates a single import record. Returns `{:ok, normalised}` or `{:error, errors}`."
  @spec validate(import_record()) :: {:ok, map()} | {:error, [String.t()]}
  def validate(record) when is_map(record) do
    missing = Enum.reject(@required_fields, &(Map.get(record, &1) not in [nil, ""]))
    type_errors = validate_types(record)
    errors = missing_errors(missing) ++ type_errors

    if Enum.empty?(errors) do
      {:ok, normalise(record)}
    else
      {:error, errors}
    end
  end

  defp validate_batch(records) do
    Enum.reduce(records, {[], []}, fn record, {ok_acc, bad_acc} ->
      case validate(record) do
        {:ok, normalised} -> {[normalised | ok_acc], bad_acc}
        {:error, errors} -> {ok_acc, [%{record: record, errors: errors} | bad_acc]}
      end
    end)
  end

  defp upsert_batch([]), do: 0

  defp upsert_batch(rows) do
    now = DateTime.utc_now()
    stamped = Enum.map(rows, &Map.merge(&1, %{inserted_at: now, updated_at: now}))

    {count, _} =
      Repo.insert_all(Product, stamped,
        on_conflict: {:replace, [:name, :price_cents, :currency, :updated_at]},
        conflict_target: :sku
      )

    count
  end

  defp normalise(record) do
    %{
      sku: record["sku"],
      name: String.trim(record["name"]),
      price_cents: record["price_cents"],
      currency: String.upcase(record["currency"]),
      active: Map.get(record, "active", true)
    }
  end

  defp validate_types(record) do
    []
    |> check_integer(record, "price_cents")
    |> check_string_length(record, "name", 255)
  end

  defp check_integer(errors, record, field) do
    case Map.get(record, field) do
      v when is_integer(v) and v >= 0 -> errors
      nil -> errors
      _ -> ["#{field} must be a non-negative integer" | errors]
    end
  end

  defp check_string_length(errors, record, field, max) do
    case Map.get(record, field) do
      v when is_binary(v) and byte_size(v) > max ->
        ["#{field} must not exceed #{max} characters" | errors]
      _ -> errors
    end
  end

  defp missing_errors(missing) do
    Enum.map(missing, fn f -> "required field '#{f}' is missing" end)
  end

  defp emit_progress(batch_num, batch_size, total) do
    :telemetry.execute(@telemetry_event,
      %{batch_size: batch_size},
      %{batch_num: batch_num, total_records: total}
    )
  end
end
```
