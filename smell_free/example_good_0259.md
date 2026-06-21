```elixir
defmodule DataPipeline.CsvImporter do
  @moduledoc """
  Processes large CSV exports concurrently using a `Task.Supervisor`.
  Each row is validated, transformed, and persisted independently.
  The pipeline returns a structured result summary including counts of
  successful rows, validation failures, and system errors.
  """

  alias DataPipeline.{RowTransformer, RowValidator, Repo}
  alias NimbleCSV.RFC4180, as: CSV

  @type import_opts :: [
          max_concurrency: pos_integer(),
          timeout_ms: pos_integer(),
          schema: module()
        ]

  @type import_result :: %{
          total: non_neg_integer(),
          succeeded: non_neg_integer(),
          validation_errors: [%{row: non_neg_integer(), reason: term()}],
          system_errors: [%{row: non_neg_integer(), reason: term()}]
        }

  @default_concurrency 10
  @default_timeout_ms 5_000

  @doc """
  Imports records from a CSV binary, returning a structured result summary.
  Accepts `:max_concurrency`, `:timeout_ms`, and `:schema` options.
  """
  @spec import_csv(binary(), import_opts()) :: {:ok, import_result()} | {:error, :parse_failed}
  def import_csv(csv_binary, opts \\ []) when is_binary(csv_binary) do
    max_concurrency = Keyword.get(opts, :max_concurrency, @default_concurrency)
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    schema = Keyword.fetch!(opts, :schema)

    rows = parse_rows(csv_binary)
    results = process_rows(rows, schema, max_concurrency, timeout_ms)
    {:ok, aggregate_results(results)}
  rescue
    _e -> {:error, :parse_failed}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp parse_rows(csv_binary) do
    csv_binary
    |> CSV.parse_string(skip_headers: true)
    |> Enum.with_index(2)
  end

  defp process_rows(rows, schema, max_concurrency, timeout_ms) do
    Task.Supervisor.async_stream(
      DataPipeline.TaskSupervisor,
      rows,
      fn {row, index} -> process_single_row(row, index, schema) end,
      max_concurrency: max_concurrency,
      timeout: timeout_ms,
      on_timeout: :kill_task
    )
    |> Enum.map(&unwrap_task_result/1)
  end

  defp process_single_row(raw_row, row_index, schema) do
    with {:ok, attrs} <- RowTransformer.transform(raw_row, schema),
         :ok <- RowValidator.validate(attrs, schema),
         {:ok, _record} <- Repo.insert(struct(schema, attrs)) do
      {:ok, row_index}
    else
      {:error, reason} -> {:error, row_index, reason}
    end
  end

  defp unwrap_task_result({:ok, result}), do: result
  defp unwrap_task_result({:exit, :timeout}), do: {:system_error, :timeout}
  defp unwrap_task_result({:exit, reason}), do: {:system_error, reason}

  defp aggregate_results(results) do
    Enum.reduce(results, empty_summary(), &accumulate_result/2)
  end

  defp accumulate_result({:ok, _index}, acc) do
    %{acc | total: acc.total + 1, succeeded: acc.succeeded + 1}
  end

  defp accumulate_result({:error, index, reason}, acc) do
    entry = %{row: index, reason: reason}
    %{acc | total: acc.total + 1, validation_errors: [entry | acc.validation_errors]}
  end

  defp accumulate_result({:system_error, reason}, acc) do
    entry = %{row: :unknown, reason: reason}
    %{acc | total: acc.total + 1, system_errors: [entry | acc.system_errors]}
  end

  defp empty_summary do
    %{total: 0, succeeded: 0, validation_errors: [], system_errors: []}
  end
end

defmodule DataPipeline.Supervisor do
  @moduledoc """
  Root supervisor for the data pipeline subsystem. Starts and supervises
  the `Task.Supervisor` used for concurrent row processing.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(_opts) do
    children = [
      {Task.Supervisor, name: DataPipeline.TaskSupervisor}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
```
