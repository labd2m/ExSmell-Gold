```elixir
defmodule Imports.CSVMapper do
  @moduledoc """
  Maps CSV rows to domain structs using a declarative column mapping DSL.
  Mappings define a source column name, a target field, an optional type
  coercion, and an optional transform function. Rows that fail required
  field coercions are rejected with structured error records rather than
  raising exceptions.
  """

  @type column_mapping :: %{
          source: String.t(),
          target: atom(),
          type: :string | :integer | :float | :boolean | :date,
          required: boolean(),
          transform: (term() -> term()) | nil
        }

  @type raw_row :: %{String.t() => String.t()}
  @type mapped_row :: %{atom() => term()}
  @type row_error :: %{source_row: raw_row(), errors: [String.t()]}
  @type map_result :: %{rows: [mapped_row()], errors: [row_error()]}

  @doc """
  Maps a list of raw string-keyed CSV rows to typed maps using `mappings`.
  Returns all successfully mapped rows and a list of per-row errors.
  """
  @spec map_rows([raw_row()], [column_mapping()]) :: map_result()
  def map_rows(rows, mappings) when is_list(rows) and is_list(mappings) do
    {mapped, errors} =
      Enum.reduce(rows, {[], []}, fn raw, {ok_acc, err_acc} ->
        case map_row(raw, mappings) do
          {:ok, row} -> {[row | ok_acc], err_acc}
          {:error, errs} -> {ok_acc, [%{source_row: raw, errors: errs} | err_acc]}
        end
      end)

    %{rows: Enum.reverse(mapped), errors: Enum.reverse(errors)}
  end

  @doc "Maps a single raw row using the provided column mappings."
  @spec map_row(raw_row(), [column_mapping()]) ::
          {:ok, mapped_row()} | {:error, [String.t()]}
  def map_row(raw, mappings) when is_map(raw) and is_list(mappings) do
    {result, errors} =
      Enum.reduce(mappings, {%{}, []}, fn mapping, {acc, errs} ->
        raw_value = Map.get(raw, mapping.source)
        apply_mapping(mapping, raw_value, acc, errs)
      end)

    if Enum.empty?(errors), do: {:ok, result}, else: {:error, Enum.reverse(errors)}
  end

  defp apply_mapping(%{required: true, source: src}, nil, acc, errs) do
    {acc, ["required column '#{src}' is missing" | errs]}
  end

  defp apply_mapping(%{required: false}, nil, acc, errs), do: {acc, errs}

  defp apply_mapping(%{type: type, target: target, transform: transform, source: src}, raw, acc, errs) do
    case coerce(type, raw) do
      {:ok, value} ->
        final = if is_function(transform, 1), do: transform.(value), else: value
        {Map.put(acc, target, final), errs}

      :error ->
        {acc, ["column '#{src}' could not be coerced to #{type}" | errs]}
    end
  end

  defp coerce(:string, v) when is_binary(v), do: {:ok, String.trim(v)}
  defp coerce(:integer, v) do
    case Integer.parse(String.trim(v)) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end
  defp coerce(:float, v) do
    case Float.parse(String.trim(v)) do
      {f, ""} -> {:ok, f}
      _ -> :error
    end
  end
  defp coerce(:boolean, v) when v in ~w(true 1 yes), do: {:ok, true}
  defp coerce(:boolean, v) when v in ~w(false 0 no), do: {:ok, false}
  defp coerce(:boolean, _), do: :error
  defp coerce(:date, v) do
    case Date.from_iso8601(String.trim(v)) do
      {:ok, date} -> {:ok, date}
      _ -> :error
    end
  end
  defp coerce(_, _), do: :error
end
```
