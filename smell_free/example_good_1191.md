```elixir
defmodule Imports.CsvImporter do
  @moduledoc """
  Parses and validates CSV uploads against a declared column schema,
  accumulates per-row validation errors, and returns structured import
  results without touching the database for invalid rows.
  """

  alias Imports.RowValidator

  @type column_spec :: %{
          name: atom(),
          type: :string | :integer | :decimal | :date | :boolean,
          required: boolean()
        }

  @type row_result ::
          {:ok, map()}
          | {:error, %{row: pos_integer(), errors: [{atom(), atom()}]}}

  @type import_result :: %{
          valid: [map()],
          invalid: [%{row: pos_integer(), errors: [{atom(), atom()}]}],
          total: non_neg_integer()
        }

  @spec parse(binary(), [column_spec()]) :: {:ok, import_result()} | {:error, :bad_csv}
  def parse(csv_binary, column_specs) when is_binary(csv_binary) and is_list(column_specs) do
    case decode_csv(csv_binary) do
      {:ok, [headers | data_rows]} ->
        column_map = build_column_map(headers, column_specs)
        results = process_rows(data_rows, column_map, column_specs)
        {:ok, aggregate(results)}

      {:error, _} ->
        {:error, :bad_csv}
    end
  end

  @spec process_rows([[String.t()]], %{String.t() => atom()}, [column_spec()]) :: [row_result()]
  defp process_rows(rows, column_map, specs) do
    rows
    |> Enum.with_index(2)
    |> Enum.map(fn {cells, row_num} ->
      raw = zip_row(cells, column_map)
      validate_row(raw, specs, row_num)
    end)
  end

  @spec validate_row(map(), [column_spec()], pos_integer()) :: row_result()
  defp validate_row(raw, specs, row_num) do
    case RowValidator.validate(raw, specs) do
      {:ok, typed} -> {:ok, typed}
      {:error, errors} -> {:error, %{row: row_num, errors: errors}}
    end
  end

  @spec aggregate([row_result()]) :: import_result()
  defp aggregate(results) do
    Enum.reduce(results, %{valid: [], invalid: [], total: 0}, fn
      {:ok, row}, acc ->
        %{acc | valid: [row | acc.valid], total: acc.total + 1}

      {:error, error}, acc ->
        %{acc | invalid: [error | acc.invalid], total: acc.total + 1}
    end)
    |> Map.update!(:valid, &Enum.reverse/1)
    |> Map.update!(:invalid, &Enum.reverse/1)
  end

  @spec build_column_map([String.t()], [column_spec()]) :: %{String.t() => atom()}
  defp build_column_map(headers, specs) do
    spec_names = Map.new(specs, fn s -> {to_string(s.name), s.name} end)
    Map.new(headers, fn h -> {h, Map.get(spec_names, String.trim(h))} end)
  end

  @spec zip_row([String.t()], %{String.t() => atom()}) :: map()
  defp zip_row(cells, column_map) do
    column_map
    |> Map.keys()
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {header, idx}, acc ->
      case Map.fetch(column_map, header) do
        {:ok, key} when not is_nil(key) ->
          Map.put(acc, key, Enum.at(cells, idx, ""))

        _ ->
          acc
      end
    end)
  end

  @spec decode_csv(binary()) :: {:ok, [[String.t()]]} | {:error, term()}
  defp decode_csv(binary) do
    rows =
      binary
      |> String.split("\n", trim: true)
      |> Enum.map(&String.split(&1, ","))

    {:ok, rows}
  rescue
    e -> {:error, e}
  end
end
```
