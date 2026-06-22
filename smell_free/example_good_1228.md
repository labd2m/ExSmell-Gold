```elixir
defmodule DataImport.CSVPipeline do
  @moduledoc """
  Processes large CSV files concurrently using streamed task execution.
  Each row is independently parsed, validated, and persisted. The
  pipeline collects per-row outcomes into a structured result summary.
  """

  alias DataImport.{RowParser, RowValidator, RowPersistor}

  @type summary :: %{ok: non_neg_integer(), error: non_neg_integer(), errors: list(map())}

  @default_concurrency System.schedulers_online() * 2

  @spec run(String.t(), keyword()) :: {:ok, summary()} | {:error, atom()}
  def run(file_path, opts \\ []) when is_binary(file_path) do
    concurrency = Keyword.get(opts, :concurrency, @default_concurrency)

    with {:ok, stream} <- open_stream(file_path) do
      summary =
        stream
        |> Stream.drop(1)
        |> Task.async_stream(&process_row/1,
          max_concurrency: concurrency,
          on_timeout: :kill_task,
          timeout: 5_000
        )
        |> Enum.reduce(%{ok: 0, error: 0, errors: []}, &accumulate_result/2)

      {:ok, Map.update!(summary, :errors, &Enum.reverse/1)}
    end
  end

  defp open_stream(path) do
    if File.exists?(path) do
      {:ok, File.stream!(path, [:utf8])}
    else
      {:error, :file_not_found}
    end
  end

  defp process_row(raw_line) do
    with {:ok, row} <- RowParser.parse(raw_line),
         :ok <- RowValidator.validate(row) do
      RowPersistor.upsert(row)
    end
  end

  defp accumulate_result({:ok, {:ok, _}}, acc), do: Map.update!(acc, :ok, &(&1 + 1))

  defp accumulate_result({:ok, {:error, reason}}, acc) do
    acc
    |> Map.update!(:error, &(&1 + 1))
    |> Map.update!(:errors, &[%{reason: reason} | &1])
  end

  defp accumulate_result({:exit, reason}, acc) do
    acc
    |> Map.update!(:error, &(&1 + 1))
    |> Map.update!(:errors, &[%{reason: {:task_exit, reason}} | &1])
  end
end

defmodule DataImport.RowParser do
  @moduledoc """
  Parses a single raw CSV line into a validated row map.
  """

  @spec parse(String.t()) :: {:ok, map()} | {:error, :parse_error}
  def parse(line) when is_binary(line) do
    case line |> String.trim() |> String.split(",") do
      [id, name, email] when id != "" and name != "" and email != "" ->
        {:ok, %{external_id: id, name: String.trim(name), email: String.trim(email)}}
      _ ->
        {:error, :parse_error}
    end
  end
end

defmodule DataImport.RowValidator do
  @moduledoc """
  Validates field constraints on a parsed row map.
  """

  @email_regex ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/

  @spec validate(map()) :: :ok | {:error, atom()}
  def validate(%{name: name, email: email})
      when is_binary(name) and is_binary(email) do
    cond do
      String.length(name) < 2 -> {:error, :name_too_short}
      not Regex.match?(@email_regex, email) -> {:error, :invalid_email}
      true -> :ok
    end
  end

  def validate(_), do: {:error, :malformed_row}
end
```
