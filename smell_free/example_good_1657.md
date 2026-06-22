```elixir
defmodule FileProcessor.Job do
  @moduledoc """
  Represents a single file processing job submitted to the worker pool.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          path: String.t(),
          processor: module(),
          submitted_at: DateTime.t()
        }

  defstruct [:id, :path, :processor, :submitted_at]
end

defmodule FileProcessor.Result do
  @moduledoc """
  The outcome of a completed file processing job.
  """

  @type t :: %__MODULE__{
          job_id: String.t(),
          status: :ok | :error,
          output: term(),
          duration_ms: non_neg_integer()
        }

  defstruct [:job_id, :status, :output, :duration_ms]
end

defmodule FileProcessor.Pool do
  use Supervisor

  @moduledoc """
  Manages a fixed pool of supervised file processor workers.
  Jobs are submitted via `FileProcessor.Pool.submit/1` and results
  are delivered asynchronously to the caller process.
  """

  @pool_size 4

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec submit(FileProcessor.Job.t()) :: {:ok, reference()}
  def submit(%FileProcessor.Job{} = job) do
    ref = make_ref()
    caller = self()

    Task.Supervisor.start_child(FileProcessor.TaskSupervisor, fn ->
      result = execute_job(job)
      send(caller, {:file_processor_result, ref, result})
    end)

    {:ok, ref}
  end

  @impl Supervisor
  def init(_opts) do
    children = [
      {Task.Supervisor, name: FileProcessor.TaskSupervisor, max_children: @pool_size}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp execute_job(%FileProcessor.Job{id: id, path: path, processor: processor}) do
    start = System.monotonic_time(:millisecond)

    {status, output} =
      case processor.process(path) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, reason}
      end

    duration = System.monotonic_time(:millisecond) - start

    %FileProcessor.Result{
      job_id: id,
      status: status,
      output: output,
      duration_ms: duration
    }
  end
end

defmodule FileProcessor.CsvSummaryProcessor do
  @moduledoc """
  Reads a CSV file and returns a summary of row count and column names.
  Implements the processor interface expected by `FileProcessor.Pool`.
  """

  @spec process(String.t()) :: {:ok, map()} | {:error, term()}
  def process(path) when is_binary(path) do
    case File.read(path) do
      {:ok, contents} -> parse_summary(contents)
      {:error, reason} -> {:error, {:file_read_failed, reason}}
    end
  end

  defp parse_summary(contents) do
    lines = String.split(contents, "\n", trim: true)

    case lines do
      [] ->
        {:error, :empty_file}

      [header | data_lines] ->
        columns = header |> String.split(",") |> Enum.map(&String.trim/1)
        {:ok, %{row_count: length(data_lines), columns: columns, column_count: length(columns)}}
    end
  end
end
```
