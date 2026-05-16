```elixir
defmodule Workers.JobRunner do
  @moduledoc """
  Executes background job functions with optional telemetry wrapping
  and safe (rescue-based) error handling modes.
  Used by the job queue to run scheduled and on-demand tasks.
  """

  require Logger

  @doc """
  Runs a job function, optionally wrapping it for telemetry or safe execution.

  ## Arguments

    * `job_fn` — A zero-arity function representing the job body.
    * `opts` — Keyword list of options.

  ## Options

    * `:job_name` — Label used in log and telemetry output.
    * `:safe` — When `true`, rescues exceptions and returns
      `{:ok, result} | {:error, exception}` instead of letting the
      exception propagate.
    * `:telemetry` — When `true`, measures wall-clock duration and returns
      `{:ok, result, %{duration_ms: integer, job_name: string}}`.
      Overrides `:safe` for the return shape.

  ## Examples

      iex> run(fn -> do_work() end)
      :done  # whatever the job returns

      iex> run(fn -> do_work() end, safe: true)
      {:ok, :done}

      iex> run(fn -> raise "boom" end, safe: true)
      {:error, %RuntimeError{message: "boom"}}

      iex> run(fn -> do_work() end, telemetry: true, job_name: "SyncInventory")
      {:ok, :done, %{duration_ms: 142, job_name: "SyncInventory"}}

  """

  def run(job_fn, opts \\ []) when is_function(job_fn, 0) and is_list(opts) do
    job_name = Keyword.get(opts, :job_name, "unnamed_job")

    cond do
      opts[:telemetry] == true ->
        start_time = System.monotonic_time(:millisecond)

        result =
          try do
            job_fn.()
          rescue
            e ->
              Logger.error("[#{job_name}] failed: #{Exception.message(e)}")
              reraise e, __STACKTRACE__
          end

        duration_ms = System.monotonic_time(:millisecond) - start_time
        Logger.info("[#{job_name}] completed in #{duration_ms}ms")
        {:ok, result, %{duration_ms: duration_ms, job_name: job_name}}

      opts[:safe] == true ->
        try do
          result = job_fn.()
          {:ok, result}
        rescue
          e ->
            Logger.error("[#{job_name}] rescued error: #{Exception.message(e)}")
            {:error, e}
        end

      true ->
        job_fn.()
    end
  end

  @doc """
  Runs a list of job functions concurrently and collects results.
  Returns a list of `{:ok, result} | {:error, term}` tuples.
  """
  def run_concurrent(job_fns, opts \\ []) when is_list(job_fns) do
    timeout = Keyword.get(opts, :timeout, 30_000)

    job_fns
    |> Enum.map(fn fn_ ->
      Task.async(fn -> run(fn_, safe: true) end)
    end)
    |> Task.await_many(timeout)
  end

  @doc """
  Retries a job function up to `max_attempts` times on failure.
  Returns `{:ok, result}` or `{:error, last_exception}`.
  """
  def run_with_retry(job_fn, max_attempts \\ 3) when is_function(job_fn, 0) do
    Enum.reduce_while(1..max_attempts, {:error, nil}, fn attempt, _acc ->
      case run(job_fn, safe: true) do
        {:ok, _} = success ->
          {:halt, success}

        {:error, e} ->
          Logger.warning("Attempt #{attempt}/#{max_attempts} failed: #{Exception.message(e)}")

          if attempt < max_attempts do
            Process.sleep(attempt * 500)
            {:cont, {:error, e}}
          else
            {:halt, {:error, e}}
          end
      end
    end)
  end

  @doc """
  Measures wall-clock execution time of a function and logs it.
  """
  def timed(label, fun) when is_function(fun, 0) do
    t0 = System.monotonic_time(:millisecond)
    result = fun.()
    elapsed = System.monotonic_time(:millisecond) - t0
    Logger.info("#{label} took #{elapsed}ms")
    result
  end
end
```
