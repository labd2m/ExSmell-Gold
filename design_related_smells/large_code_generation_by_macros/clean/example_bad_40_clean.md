```elixir
defmodule MyApp.Pipeline.StageDSL do
  @moduledoc """
  DSL for declaring ordered processing stages in a data pipeline module.

  Example:

      defmodule MyApp.Pipeline.InvoiceIngestion do
        use MyApp.Pipeline.StageDSL

        pipeline_stage :parse_csv,
          processor:    MyApp.Processors.CsvParser,
          concurrency:  4,
          timeout_ms:   10_000,
          on_error:     :skip

        pipeline_stage :validate_rows,
          processor:   MyApp.Processors.RowValidator,
          concurrency: 8,
          timeout_ms:  5_000,
          on_error:    :halt

        pipeline_stage :enrich_supplier,
          processor:   MyApp.Processors.SupplierEnricher,
          concurrency: 2,
          timeout_ms:  15_000,
          on_error:    :retry,
          max_retries: 3

        pipeline_stage :persist,
          processor:  MyApp.Processors.InvoicePersister,
          concurrency: 1,
          timeout_ms:  30_000,
          on_error:    :halt
      end
  """

  defmacro __using__(_opts) do
    quote do
      import MyApp.Pipeline.StageDSL, only: [pipeline_stage: 2]
      Module.register_attribute(__MODULE__, :pipeline_stages, accumulate: true)
      @before_compile MyApp.Pipeline.StageDSL
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      def pipeline_stages, do: Enum.reverse(@pipeline_stages)

      def stage(name) do
        Enum.find(@pipeline_stages, fn s -> s.name == name end)
      end
    end
  end

  defmacro pipeline_stage(name, opts) do
    quote do
      name = unquote(name)
      opts = unquote(opts)

      unless is_atom(name) do
        raise ArgumentError,
              "pipeline_stage/2: name must be an atom, got #{inspect(name)}"
      end

      processor = Keyword.fetch!(opts, :processor)

      unless is_atom(processor) do
        raise ArgumentError,
              "pipeline_stage/2: :processor must be a module atom, got #{inspect(processor)}"
      end

      :ok = Code.ensure_compiled!(processor)

      unless function_exported?(processor, :process, 1) do
        raise ArgumentError,
              "pipeline_stage/2: processor #{inspect(processor)} must export process/1"
      end

      concurrency = Keyword.get(opts, :concurrency, 1)

      unless is_integer(concurrency) and concurrency >= 1 do
        raise ArgumentError,
              "pipeline_stage/2: :concurrency must be a positive integer, " <>
                "got #{inspect(concurrency)}"
      end

      timeout_ms = Keyword.get(opts, :timeout_ms, 5_000)

      unless is_integer(timeout_ms) and timeout_ms > 0 do
        raise ArgumentError,
              "pipeline_stage/2: :timeout_ms must be a positive integer, " <>
                "got #{inspect(timeout_ms)}"
      end

      valid_strategies = [:halt, :skip, :retry, :dead_letter]
      on_error = Keyword.get(opts, :on_error, :halt)

      unless on_error in valid_strategies do
        raise ArgumentError,
              "pipeline_stage/2: :on_error must be one of #{inspect(valid_strategies)}, " <>
                "got #{inspect(on_error)}"
      end

      max_retries = Keyword.get(opts, :max_retries, 0)

      if on_error != :retry and max_retries > 0 do
        raise ArgumentError,
              "pipeline_stage/2: :max_retries is only valid when :on_error is :retry, " <>
                "stage #{inspect(name)} has :on_error #{inspect(on_error)}"
      end

      unless is_integer(max_retries) and max_retries >= 0 do
        raise ArgumentError,
              "pipeline_stage/2: :max_retries must be a non-negative integer, " <>
                "got #{inspect(max_retries)}"
      end

      existing = Module.get_attribute(__MODULE__, :pipeline_stages)

      if Enum.any?(existing, fn s -> s.name == name end) do
        raise ArgumentError,
              "pipeline_stage/2: duplicate stage #{inspect(name)} in #{inspect(__MODULE__)}"
      end

      stage = %{
        name:        name,
        processor:   processor,
        concurrency: concurrency,
        timeout_ms:  timeout_ms,
        on_error:    on_error,
        max_retries: max_retries
      }

      @pipeline_stages stage
    end
  end

  @doc """
  Executes the pipeline defined in `pipeline_module` against the given input
  list, passing data through each stage in declaration order.
  """
  @spec run(module(), [any()]) :: {:ok, [any()]} | {:error, atom(), any()}
  def run(pipeline_module, input) do
    pipeline_module.pipeline_stages()
    |> Enum.reduce_while({:ok, input}, fn stage, {:ok, data} ->
      case execute_stage(stage, data) do
        {:ok, result}          -> {:cont, {:ok, result}}
        {:error, _reason} = e  ->
          if stage.on_error == :halt do
            {:halt, e}
          else
            {:cont, {:ok, data}}
          end
      end
    end)
  end

  defp execute_stage(stage, data) do
    tasks =
      data
      |> Enum.chunk_every(max(1, div(length(data), stage.concurrency)))
      |> Enum.map(fn chunk ->
        Task.async(fn -> Enum.map(chunk, &stage.processor.process/1) end)
      end)

    results =
      Task.await_many(tasks, stage.timeout_ms)
      |> List.flatten()

    {:ok, results}
  rescue
    e -> {:error, e}
  end
end
```
