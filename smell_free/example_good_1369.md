**File:** `example_good_1369.md`

```elixir
defmodule DataPipeline.CSV do
  @moduledoc """
  Parses and validates CSV files for bulk import operations.
  Returns structured results or detailed error reports per row.
  """

  alias DataPipeline.CSV.{Row, ParseError}

  @type parse_result :: {:ok, [Row.t()]} | {:error, [ParseError.t()]}

  @required_headers ~w(id name email amount_cents currency)

  @spec parse(String.t()) :: parse_result()
  def parse(raw_csv) when is_binary(raw_csv) do
    lines = String.split(raw_csv, "\n", trim: true)

    with {:ok, headers, data_lines} <- extract_headers(lines),
         :ok <- validate_headers(headers) do
      build_rows(headers, data_lines)
    end
  end

  defp extract_headers([header_line | rest]) do
    headers = header_line |> String.split(",") |> Enum.map(&String.trim/1)
    {:ok, headers, rest}
  end

  defp extract_headers([]) do
    {:error, [ParseError.new(0, "File is empty or missing header row")]}
  end

  defp validate_headers(headers) do
    missing = @required_headers -- headers

    if missing == [] do
      :ok
    else
      {:error, [ParseError.new(0, "Missing required headers: #{Enum.join(missing, ", ")}")]}
    end
  end

  defp build_rows(headers, data_lines) do
    results =
      data_lines
      |> Enum.with_index(2)
      |> Enum.map(fn {line, line_number} ->
        parse_row(headers, line, line_number)
      end)

    errors = Enum.flat_map(results, fn
      {:error, errs} -> errs
      {:ok, _} -> []
    end)

    if errors == [] do
      rows = Enum.map(results, fn {:ok, row} -> row end)
      {:ok, rows}
    else
      {:error, errors}
    end
  end

  defp parse_row(headers, line, line_number) do
    values = line |> String.split(",") |> Enum.map(&String.trim/1)

    if length(values) != length(headers) do
      {:error, [ParseError.new(line_number, "Expected #{length(headers)} columns, got #{length(values)}")]}
    else
      raw = headers |> Enum.zip(values) |> Map.new()
      Row.from_map(raw, line_number)
    end
  end
end

defmodule DataPipeline.CSV.Row do
  @moduledoc "Represents a validated and typed row from an import CSV."

  alias DataPipeline.CSV.ParseError

  @enforce_keys [:id, :name, :email, :amount_cents, :currency, :line_number]
  defstruct [:id, :name, :email, :amount_cents, :currency, :line_number]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          email: String.t(),
          amount_cents: pos_integer(),
          currency: String.t(),
          line_number: pos_integer()
        }

  @spec from_map(map(), pos_integer()) :: {:ok, t()} | {:error, [ParseError.t()]}
  def from_map(%{"id" => id, "name" => name, "email" => email,
                  "amount_cents" => raw_amount, "currency" => currency}, line) do
    with {:ok, amount} <- parse_positive_integer(raw_amount, "amount_cents", line),
         :ok <- validate_email(email, line),
         :ok <- validate_currency(currency, line) do
      {:ok, %__MODULE__{
        id: id,
        name: name,
        email: email,
        amount_cents: amount,
        currency: String.upcase(currency),
        line_number: line
      }}
    end
  end

  defp parse_positive_integer(raw, field, line) do
    case Integer.parse(raw) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> {:error, [ParseError.new(line, "#{field} must be a positive integer, got: #{raw}")]}
    end
  end

  defp validate_email(email, line) do
    if String.match?(email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/) do
      :ok
    else
      {:error, [ParseError.new(line, "Invalid email format: #{email}")]}
    end
  end

  defp validate_currency(currency, line) do
    if String.match?(currency, ~r/^[A-Za-z]{3}$/) do
      :ok
    else
      {:error, [ParseError.new(line, "Currency must be a 3-letter code, got: #{currency}")]}
    end
  end
end

defmodule DataPipeline.CSV.ParseError do
  @moduledoc "Represents a single parse or validation error at a specific CSV line."

  @enforce_keys [:line_number, :message]
  defstruct [:line_number, :message]

  @type t :: %__MODULE__{
          line_number: non_neg_integer(),
          message: String.t()
        }

  @spec new(non_neg_integer(), String.t()) :: t()
  def new(line_number, message), do: %__MODULE__{line_number: line_number, message: message}
end
```
