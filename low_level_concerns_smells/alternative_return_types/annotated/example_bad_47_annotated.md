# Annotated Example — Alternative Return Types

## Metadata

- **Smell name:** Alternative Return Types
- **Expected smell location:** `DataImport.CsvProcessor.process/2`, around the `opts[:mode]` branching
- **Affected function(s):** `process/2`
- **Short explanation:** Depending on the `:mode` option, the function returns a count integer, a list of `{:ok, record} | {:error, errors}` tagged tuples, or a `%{inserted: integer, failed: integer, errors: [map]}` summary map — three incompatible return shapes.

---

```elixir
defmodule DataImport.CsvProcessor do
  @moduledoc """
  Processes CSV file uploads for bulk data import.
  Supports dry-run validation, full import, and batch-result reporting modes.
  """

  alias DataImport.Repo
  alias DataImport.Schema.ImportRecord
  alias DataImport.Validators.ImportRowValidator

  @required_columns ~w(name email role department)
  @batch_size 100

  @doc """
  Processes a CSV binary for import.

  ## Options

    * `:mode` — Controls processing behavior and return type:
      - `:validate` (default) — Validates all rows and returns a list of
        `{:ok, attrs_map} | {:error, %{row: integer, errors: [string]}}`.
      - `:import` — Inserts valid rows and returns a summary map:
        `%{inserted: integer, failed: integer, errors: [%{row: integer, errors: [string]}]}`.
      - `:count` — Returns just the integer count of valid rows without
        persisting anything.
    * `:strict` — When `true`, aborts the entire import on the first error.
      Only used with `:import` mode.

  ## Examples

      iex> process(csv_binary, mode: :validate)
      [{:ok, %{name: "Alice", ...}}, {:error, %{row: 3, errors: ["email blank"]}}, ...]

      iex> process(csv_binary, mode: :import)
      %{inserted: 42, failed: 2, errors: [%{row: 3, errors: ["email blank"]}]}

      iex> process(csv_binary, mode: :count)
      44

  """

  # VALIDATION: SMELL START - Alternative Return Types
  # VALIDATION: This is a smell because the three values of the :mode option
  # VALIDATION: produce three entirely incompatible return types: a list of
  # VALIDATION: tagged tuples, a summary statistics map, and a plain integer.
  # VALIDATION: Any orchestration code that calls process/2 must branch on the
  # VALIDATION: mode value it passed to safely handle the result.
  def process(csv_binary, opts \\ []) when is_binary(csv_binary) and is_list(opts) do
    mode = Keyword.get(opts, :mode, :validate)
    strict = Keyword.get(opts, :strict, false)

    rows = parse_csv(csv_binary)

    case mode do
      :count ->
        Enum.count(rows, fn row ->
          case ImportRowValidator.validate(row) do
            {:ok, _} -> true
            _ -> false
          end
        end)

      :validate ->
        rows
        |> Enum.with_index(1)
        |> Enum.map(fn {row, line} ->
          case ImportRowValidator.validate(row) do
            {:ok, attrs} -> {:ok, attrs}
            {:error, errors} -> {:error, %{row: line, errors: errors}}
          end
        end)

      :import ->
        {inserted, failed, errors} =
          rows
          |> Enum.with_index(1)
          |> Enum.chunk_every(@batch_size)
          |> Enum.reduce({0, 0, []}, fn batch, {ins, fail, errs} ->
            process_batch(batch, ins, fail, errs, strict)
          end)

        %{inserted: inserted, failed: failed, errors: errors}
    end
  end
  # VALIDATION: SMELL END

  defp parse_csv(binary) do
    [header_line | data_lines] = String.split(binary, "\n", trim: true)
    headers = String.split(header_line, ",") |> Enum.map(&String.trim/1)

    Enum.map(data_lines, fn line ->
      values = String.split(line, ",") |> Enum.map(&String.trim/1)
      Enum.zip(headers, values) |> Map.new()
    end)
  end

  defp process_batch(batch, inserted_acc, failed_acc, error_acc, strict) do
    Enum.reduce(batch, {inserted_acc, failed_acc, error_acc}, fn {row, line}, {ins, fail, errs} ->
      case ImportRowValidator.validate(row) do
        {:ok, attrs} ->
          case insert_record(attrs) do
            {:ok, _} ->
              {ins + 1, fail, errs}

            {:error, changeset} ->
              errors = format_changeset_errors(changeset)

              if strict do
                raise "Import aborted at row #{line}: #{inspect(errors)}"
              end

              {ins, fail + 1, [%{row: line, errors: errors} | errs]}
          end

        {:error, errors} ->
          if strict do
            raise "Validation failed at row #{line}: #{inspect(errors)}"
          end

          {ins, fail + 1, [%{row: line, errors: errors} | errs]}
      end
    end)
  end

  defp insert_record(attrs) do
    %ImportRecord{}
    |> ImportRecord.changeset(attrs)
    |> Repo.insert()
  end

  defp format_changeset_errors(%{errors: errors}) do
    Enum.map(errors, fn {field, {msg, _}} -> "#{field} #{msg}" end)
  end

  @doc """
  Returns the list of column names required in the CSV.
  """
  def required_columns, do: @required_columns
end
```
