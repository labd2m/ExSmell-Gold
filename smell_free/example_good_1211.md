```elixir
defmodule MyApp.Infra.TaskThrottler do
  @moduledoc """
  Executes a list of tasks concurrently while honouring a configurable
  rate limit expressed as a maximum number of tasks per time window.
  Tasks that would exceed the rate are delayed automatically without
  requiring the caller to manage timing.

  Unlike `Task.async_stream`, which limits concurrency, this module
  limits throughput — useful for API calls where the external system
  enforces a requests-per-second ceiling.
  """

  @type task_fn :: (-> term())

  @doc """
  Runs all `funs` in order, throttled to `max_per_window` tasks per
  `window_ms` milliseconds. Returns results in input order.
  """
  @spec run_throttled([task_fn()], pos_integer(), pos_integer()) :: [term()]
  def run_throttled(funs, max_per_window, window_ms)
      when is_list(funs) and is_integer(max_per_window) and max_per_window > 0 and
             is_integer(window_ms) and window_ms > 0 do
    funs
    |> Enum.chunk_every(max_per_window)
    |> Enum.flat_map(fn batch ->
      start_ms = System.monotonic_time(:millisecond)
      results = run_batch(batch)
      elapsed_ms = System.monotonic_time(:millisecond) - start_ms
      remaining_ms = window_ms - elapsed_ms

      if remaining_ms > 0, do: Process.sleep(remaining_ms)

      results
    end)
  end

  @doc """
  Same as `run_throttled/3` but runs tasks within each window batch
  concurrently rather than sequentially.
  """
  @spec run_throttled_concurrent([task_fn()], pos_integer(), pos_integer(), pos_integer()) ::
          [term()]
  def run_throttled_concurrent(funs, max_per_window, window_ms, task_timeout_ms \\ 30_000)
      when is_list(funs) do
    funs
    |> Enum.chunk_every(max_per_window)
    |> Enum.flat_map(fn batch ->
      start_ms = System.monotonic_time(:millisecond)

      results =
        batch
        |> Task.async_stream(fn f -> f.() end,
          timeout: task_timeout_ms,
          on_timeout: :kill_task
        )
        |> Enum.map(fn
          {:ok, result} -> result
          {:exit, _} -> {:error, :timeout}
        end)

      elapsed_ms = System.monotonic_time(:millisecond) - start_ms
      remaining_ms = window_ms - elapsed_ms

      if remaining_ms > 0, do: Process.sleep(remaining_ms)

      results
    end)
  end

  @spec run_batch([task_fn()]) :: [term()]
  defp run_batch(batch), do: Enum.map(batch, fn f -> f.() end)
end
```
