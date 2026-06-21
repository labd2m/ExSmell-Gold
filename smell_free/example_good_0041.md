```elixir
defmodule DataPipeline.CSVIngestion do
  @moduledoc """
  Streams a CSV file through parse, normalize, and validate stages.
  Records that pass all stages are forwarded to a caller-supplied sink function.
  Memory consumption remains constant relative to file size because the pipeline
  is built entirely from lazy Elixir streams.
  """

  @type row :: %{String.t() => String.t()}
  @type sink_fn :: (row() -> :ok)
  @type summary :: %{accepted: non_neg_integer(), rejected: non_neg_integer()}
  @type ingest_result :: {:ok, summary()} | {:error, :file_not_found | :permission_denied}

  @expected_columns ~w(id name email role department joined_on)
  @valid_roles ~w(admin editor viewer)
  @required_fields ~w(id name email)

  @doc """
  Reads the CSV at `path`, skipping the header row, and routes each data line
  through parsing, normalization, and validation. Valid rows are handed to `sink`.
  Returns a summary map containing accepted and rejected counts.
  """
  @spec ingest(Path.t(), sink_fn()) :: ingest_result()
  def ingest(path, sink) when is_binary(path) and is_function(sink, 1) do
    summary =
      path
      |> File.stream!([], :line)
      |> Stream.drop(1)
      |> Stream.map(&parse_line/1)
      |> Enum.reduce(%{accepted: 0, rejected: 0}, fn
        {:ok, row}, acc -> process_row(row, sink, acc)
        {:error, _}, acc -> Map.update!(acc, :rejected, &(&1 + 1))
      end)

    {:ok, summary}
  rescue
    e in File.Error -> map_file_error(e)
  end

  @doc """
  Parses a single CSV line into a string-keyed map. Returns `{:error, :malformed_row}`
  when the field count does not match the expected column count.
  """
  @spec parse_line(String.t()) :: {:ok, row()} | {:error, :malformed_row}
  def parse_line(line) when is_binary(line) do
    fields = line |> String.trim() |> String.split(",")

    if length(fields) == length(@expected_columns) do
      {:ok, Map.new(Enum.zip(@expected_columns, fields))}
    else
      {:error, :malformed_row}
    end
  end

  defp process_row(row, sink, acc) do
    normalized = normalize(row)

    if valid?(normalized) do
      sink.(normalized)
      Map.update!(acc, :accepted, &(&1 + 1))
    else
      Map.update!(acc, :rejected, &(&1 + 1))
    end
  end

  defp normalize(row) do
    row
    |> Map.new(fn {k, v} -> {k, String.trim(v)} end)
    |> Map.update("email", "", &String.downcase/1)
    |> Map.update("role", "viewer", &String.downcase/1)
  end

  defp valid?(row) do
    required_fields_present?(row) and
      valid_email_format?(row["email"]) and
      row["role"] in @valid_roles
  end

  defp required_fields_present?(row) do
    Enum.all?(@required_fields, fn field ->
      row |> Map.get(field, "") |> String.length() > 0
    end)
  end

  defp valid_email_format?(email) when is_binary(email) do
    String.match?(email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/)
  end

  defp valid_email_format?(_), do: false

  defp map_file_error(%File.Error{reason: :enoent}), do: {:error, :file_not_found}
  defp map_file_error(%File.Error{reason: :eacces}), do: {:error, :permission_denied}
  defp map_file_error(%File.Error{}), do: {:error, :file_not_found}
end
```
