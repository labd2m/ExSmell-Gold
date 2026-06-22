```elixir
defmodule Platform.ImportPipeline do
  @moduledoc """
  A composable pipeline for validating and bulk-importing records from
  CSV or JSON sources.

  Each import job passes rows through a schema-validation stage, an optional
  deduplication check, and a batched Ecto insert. A structured result report
  is returned with counts for imported, skipped, and failed rows.
  """

  alias Platform.Repo

  @type row :: map()
  @type validate_fn :: (row() -> :ok | {:error, String.t()})
  @type transform_fn :: (row() -> map())
  @type import_opts :: [
          batch_size: pos_integer(),
          on_conflict: :nothing | :replace | {:replace, [atom()]},
          conflict_target: [atom()],
          validate: validate_fn(),
          transform: transform_fn()
        ]

  @type import_result :: %{
          total: non_neg_integer(),
          imported: non_neg_integer(),
          skipped: non_neg_integer(),
          failed: non_neg_integer(),
          errors: [%{row: non_neg_integer(), reason: String.t()}]
        }

  @doc """
  Imports `rows` into `schema` after validating and transforming each row.
  Returns a structured result report.
  """
  @spec run(module(), [row()], import_opts()) :: import_result()
  def run(schema, rows, opts \\ []) when is_atom(schema) and is_list(rows) do
    batch_size = Keyword.get(opts, :batch_size, 200)
    validate_fn = Keyword.get(opts, :validate, fn _ -> :ok end)
    transform_fn = Keyword.get(opts, :transform, fn row -> row end)
    on_conflict = Keyword.get(opts, :on_conflict, :nothing)
    conflict_target = Keyword.get(opts, :conflict_target, [])

    {valid_rows, validation_errors} = validate_all(rows, validate_fn)
    transformed = Enum.map(valid_rows, fn {_idx, row} -> transform_fn.(row) end)

    {imported, insert_errors} =
      transformed
      |> Enum.chunk_every(batch_size)
      |> Enum.reduce({0, []}, fn batch, {count, errors} ->
        timestamped = add_timestamps(batch)
        repo_opts = build_repo_opts(on_conflict, conflict_target)

        case Repo.insert_all(schema, timestamped, repo_opts) do
          {n, _} -> {count + n, errors}
          {:error, reason} -> {count, [{:batch_error, reason} | errors]}
        end
      end)

    skipped = length(rows) - length(valid_rows)
    all_errors = format_validation_errors(validation_errors) ++ format_insert_errors(insert_errors)

    %{
      total: length(rows),
      imported: imported,
      skipped: skipped,
      failed: length(insert_errors),
      errors: all_errors
    }
  end

  @doc "Parses a CSV binary into a list of string-keyed maps using the first row as headers."
  @spec parse_csv(binary()) :: {:ok, [map()]} | {:error, term()}
  def parse_csv(content) when is_binary(content) do
    alias NimbleCSV.RFC4180, as: CSV

    rows =
      content
      |> CSV.parse_string(skip_headers: false)
      |> Stream.transform(nil, fn
        row, nil -> {[], row}
        row, headers -> {[Map.new(Enum.zip(headers, row))], headers}
      end)
      |> Enum.to_list()

    {:ok, rows}
  rescue
    error -> {:error, {:csv_parse_error, error}}
  end

  @doc "Parses a JSON array binary into a list of maps."
  @spec parse_json(binary()) :: {:ok, [map()]} | {:error, term()}
  def parse_json(content) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, rows} when is_list(rows) -> {:ok, rows}
      {:ok, _} -> {:error, :expected_json_array}
      {:error, reason} -> {:error, {:json_parse_error, reason}}
    end
  end

  defp validate_all(rows, validate_fn) do
    rows
    |> Enum.with_index(1)
    |> Enum.split_with(fn {row, _idx} ->
      validate_fn.(row) == :ok
    end)
    |> then(fn {valid, invalid} ->
      {valid, Enum.map(invalid, fn {row, idx} ->
        {idx, row, validate_fn.(row)}
      end)}
    end)
  end

  defp add_timestamps(rows) do
    now = DateTime.utc_now()
    Enum.map(rows, fn row ->
      row |> Map.put_new(:inserted_at, now) |> Map.put(:updated_at, now)
    end)
  end

  defp build_repo_opts(:nothing, _), do: [on_conflict: :nothing]
  defp build_repo_opts(:replace, []), do: [on_conflict: :replace_all]
  defp build_repo_opts({:replace, fields}, target), do: [on_conflict: {:replace, fields}, conflict_target: target]
  defp build_repo_opts(strategy, target), do: [on_conflict: strategy, conflict_target: target]

  defp format_validation_errors(errors) do
    Enum.map(errors, fn {idx, _row, {:error, reason}} ->
      %{row: idx, reason: reason}
    end)
  end

  defp format_insert_errors(errors) do
    Enum.map(errors, fn {:batch_error, reason} ->
      %{row: :batch, reason: inspect(reason)}
    end)
  end
end
```
