```elixir
defmodule Importer.CSV.Pipeline do
  @moduledoc """
  Processes a raw CSV binary through a staged transformation pipeline:
  parse → validate → normalize → persist.
  Each stage emits telemetry events for observability.
  Returns a structured report of successes and failures.
  """

  alias Importer.CSV.{Parser, Row, Validator, Normalizer, Persister}

  @type import_result :: %{
          total: non_neg_integer(),
          inserted: non_neg_integer(),
          rejected: non_neg_integer(),
          errors: [{non_neg_integer(), String.t()}]
        }

  @spec run(binary(), keyword()) :: {:ok, import_result()} | {:error, String.t()}
  def run(csv_binary, opts \\ []) when is_binary(csv_binary) do
    start_time = System.monotonic_time()
    source = Keyword.get(opts, :source, "unknown")

    :telemetry.execute([:importer, :csv, :start], %{}, %{source: source})

    result =
      with {:ok, rows} <- Parser.parse(csv_binary),
           validated <- Validator.validate_all(rows),
           normalized <- Normalizer.normalize_all(validated.valid),
           {:ok, report} <- Persister.persist_all(normalized, validated.invalid) do
        {:ok, report}
      end

    duration = System.monotonic_time() - start_time
    :telemetry.execute([:importer, :csv, :stop], %{duration: duration}, %{source: source})

    result
  end
end

defmodule Importer.CSV.Parser do
  @moduledoc "Parses a raw CSV binary into a list of row maps with string keys."

  @expected_headers ~w(id name email role active_since)

  @spec parse(binary()) :: {:ok, [map()]} | {:error, String.t()}
  def parse(csv_binary) when is_binary(csv_binary) do
    [header_line | data_lines] = String.split(csv_binary, "\n", trim: true)
    headers = String.split(header_line, ",")

    case headers do
      @expected_headers ->
        rows = Enum.map(data_lines, &split_row(&1, headers))
        {:ok, rows}

      _ ->
        {:error, "unexpected CSV headers: #{inspect(headers)}"}
    end
  end

  @spec split_row(String.t(), [String.t()]) :: map()
  defp split_row(line, headers) do
    values = String.split(line, ",")
    Enum.zip(headers, values) |> Map.new()
  end
end

defmodule Importer.CSV.Validator do
  @moduledoc "Validates parsed row maps, separating valid from invalid entries."

  @type validation_result :: %{valid: [map()], invalid: [{non_neg_integer(), String.t()}]}

  @spec validate_all([map()]) :: validation_result()
  def validate_all(rows) when is_list(rows) do
    rows
    |> Enum.with_index(1)
    |> Enum.reduce(%{valid: [], invalid: []}, &classify_row/2)
    |> Map.update!(:valid, &Enum.reverse/1)
    |> Map.update!(:invalid, &Enum.reverse/1)
  end

  @spec classify_row({map(), non_neg_integer()}, validation_result()) :: validation_result()
  defp classify_row({row, index}, acc) do
    case validate_row(row) do
      :ok -> %{acc | valid: [row | acc.valid]}
      {:error, reason} -> %{acc | invalid: [{index, reason} | acc.invalid]}
    end
  end

  @spec validate_row(map()) :: :ok | {:error, String.t()}
  defp validate_row(%{"id" => id, "email" => email, "name" => name}) do
    cond do
      String.trim(id) == "" -> {:error, "id is blank"}
      String.trim(name) == "" -> {:error, "name is blank"}
      not valid_email?(email) -> {:error, "invalid email: #{email}"}
      true -> :ok
    end
  end

  defp validate_row(_), do: {:error, "missing required fields"}

  @spec valid_email?(String.t()) :: boolean()
  defp valid_email?(email) when is_binary(email) do
    String.match?(email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/)
  end
end

defmodule Importer.CSV.Normalizer do
  @moduledoc "Converts validated row maps into normalized domain structs."

  @spec normalize_all([map()]) :: [Row.t()]
  def normalize_all(rows) when is_list(rows) do
    Enum.map(rows, &normalize/1)
  end

  @spec normalize(map()) :: Row.t()
  defp normalize(%{"id" => id, "name" => name, "email" => email, "role" => role} = row) do
    %Importer.CSV.Row{
      external_id: String.trim(id),
      name: String.trim(name),
      email: String.downcase(String.trim(email)),
      role: parse_role(role),
      active_since: parse_date(row["active_since"])
    }
  end

  @spec parse_role(String.t()) :: atom()
  defp parse_role("admin"), do: :admin
  defp parse_role("member"), do: :member
  defp parse_role(_), do: :viewer

  @spec parse_date(String.t() | nil) :: Date.t() | nil
  defp parse_date(nil), do: nil
  defp parse_date(""), do: nil

  defp parse_date(raw) do
    case Date.from_iso8601(String.trim(raw)) do
      {:ok, date} -> date
      {:error, _} -> nil
    end
  end
end
```
