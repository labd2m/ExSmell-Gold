```elixir
defmodule CsvImporter.Row do
  @moduledoc """
  Validated row type produced after parsing and type-coercing a raw CSV line.
  """

  @type t :: %__MODULE__{
          reference: String.t(),
          name: String.t(),
          quantity: pos_integer(),
          unit_price_cents: non_neg_integer()
        }

  defstruct [:reference, :name, :quantity, :unit_price_cents]
end

defmodule CsvImporter.Parser do
  alias CsvImporter.Row

  @moduledoc """
  Parses a raw CSV binary into a stream of validated `Row` structs.
  Lines failing validation are collected separately rather than aborting the run.
  """

  @required_headers ~w(reference name quantity unit_price_cents)

  @type parse_result :: %{rows: [Row.t()], errors: [{pos_integer(), String.t()}]}

  @spec parse(binary()) :: {:ok, parse_result()} | {:error, :invalid_headers}
  def parse(csv_binary) when is_binary(csv_binary) do
    lines = String.split(csv_binary, "\n", trim: true)

    with [header_line | data_lines] <- lines,
         {:ok, headers} <- validate_headers(header_line) do
      result = process_data_lines(headers, data_lines)
      {:ok, result}
    else
      _ -> {:error, :invalid_headers}
    end
  end

  defp validate_headers(header_line) do
    headers =
      header_line
      |> String.split(",")
      |> Enum.map(&String.trim/1)

    if Enum.all?(@required_headers, &(&1 in headers)) do
      {:ok, headers}
    else
      :error
    end
  end

  defp process_data_lines(headers, lines) do
    lines
    |> Enum.with_index(2)
    |> Enum.reduce(%{rows: [], errors: []}, fn {line, line_no}, acc ->
      case parse_line(headers, line) do
        {:ok, row} -> %{acc | rows: acc.rows ++ [row]}
        {:error, reason} -> %{acc | errors: acc.errors ++ [{line_no, reason}]}
      end
    end)
  end

  defp parse_line(headers, line) do
    values = line |> String.split(",") |> Enum.map(&String.trim/1)

    if length(values) != length(headers) do
      {:error, "column count mismatch"}
    else
      attrs = Enum.zip(headers, values) |> Map.new()
      build_row(attrs)
    end
  end

  defp build_row(attrs) do
    with {:ok, reference} <- fetch_string(attrs, "reference"),
         {:ok, name} <- fetch_string(attrs, "name"),
         {:ok, quantity} <- fetch_positive_integer(attrs, "quantity"),
         {:ok, price} <- fetch_non_negative_integer(attrs, "unit_price_cents") do
      {:ok, %Row{reference: reference, name: name, quantity: quantity, unit_price_cents: price}}
    end
  end

  defp fetch_string(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when value != "" -> {:ok, value}
      _ -> {:error, "#{key} is required"}
    end
  end

  defp fetch_positive_integer(attrs, key) do
    with {:ok, raw} <- Map.fetch(attrs, key),
         {int, ""} <- Integer.parse(raw),
         true <- int > 0 do
      {:ok, int}
    else
      _ -> {:error, "#{key} must be a positive integer"}
    end
  end

  defp fetch_non_negative_integer(attrs, key) do
    with {:ok, raw} <- Map.fetch(attrs, key),
         {int, ""} <- Integer.parse(raw),
         true <- int >= 0 do
      {:ok, int}
    else
      _ -> {:error, "#{key} must be a non-negative integer"}
    end
  end
end
```
