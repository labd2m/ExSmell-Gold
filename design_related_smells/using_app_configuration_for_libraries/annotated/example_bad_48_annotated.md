# Code Smell Example – Annotated

- **Smell name:** Using App Configuration for libraries
- **Expected smell location:** `RetryLogic.with_retry/2`
- **Affected function(s):** `with_retry/2`, `with_retry!/2`
- **Short explanation:** The library fetches `:max_attempts`, `:base_delay_ms`, and `:backoff_factor` from the global `Application Environment` instead of accepting them as call-site options. A dependent application that wants aggressive retries for payment processing and conservative retries for optional enrichment calls cannot express both policies through this library without globally changing the configuration.

```elixir
defmodule RetryLogic do
  @moduledoc """
  A retry execution library with configurable attempts, delay, and
  exponential backoff. Suitable for wrapping external API calls,
  database operations, and message deliveries.

  Configuration (config/config.exs):

      config :retry_logic,
        max_attempts: 3,
        base_delay_ms: 200,
        backoff_factor: 2.0,
        jitter: true
  """

  require Logger

  @type retry_result :: {:ok, term()} | {:error, term()}

  @doc """
  Executes the given zero-arity function with automatic retries on failure.
  Returns `{:ok, result}` if any attempt succeeds, or `{:error, last_error}`
  after all attempts are exhausted.
  """
  @spec with_retry((() -> retry_result()), keyword()) :: retry_result()
  def with_retry(fun, _opts \\ []) when is_function(fun, 0) do
    # VALIDATION: SMELL START - Using App Configuration for libraries
    # VALIDATION: This is a smell because the library reads :max_attempts,
    # :base_delay_ms, :backoff_factor, and :jitter from the global Application
    # Environment rather than accepting them as keyword arguments. Applications
    # that need a high retry budget for critical payment calls (e.g., 5 attempts,
    # 500 ms base) and a low budget for optional feature-flag lookups (e.g.,
    # 1 attempt, no delay) are forced to share the same global settings. This
    # makes the library unsuitable for reuse across multiple retry policies in
    # the same codebase.
    max_attempts = Application.fetch_env!(:retry_logic, :max_attempts)
    base_delay_ms = Application.fetch_env!(:retry_logic, :base_delay_ms)
    backoff_factor = Application.fetch_env!(:retry_logic, :backoff_factor)
    jitter = Application.fetch_env!(:retry_logic, :jitter)
    # VALIDATION: SMELL END

    do_retry(fun, max_attempts, base_delay_ms, backoff_factor, jitter, 1)
  end

  @doc """
  Same as `with_retry/2` but raises on final failure instead of returning
  `{:error, reason}`.
  """
  @spec with_retry!((() -> retry_result()), keyword()) :: term()
  def with_retry!(fun, opts \\ []) do
    case with_retry(fun, opts) do
      {:ok, result} -> result
      {:error, reason} -> raise "All retry attempts exhausted. Last error: #{inspect(reason)}"
    end
  end

  @doc """
  Executes a function a fixed number of times regardless of success or failure,
  collecting all results.
  """
  @spec repeat((() -> term()), pos_integer()) :: list(term())
  def repeat(fun, times) when is_function(fun, 0) and is_integer(times) and times > 0 do
    Enum.map(1..times, fn _ -> fun.() end)
  end

  @doc """
  Retries a function until a predicate returns true or attempts are exhausted.
  Returns `{:ok, result}` or `{:error, :exhausted}`.
  """
  @spec retry_until((-> term()), (term() -> boolean()), pos_integer()) ::
          {:ok, term()} | {:error, :exhausted}
  def retry_until(fun, predicate, limit \\ 10)
      when is_function(fun, 0) and is_function(predicate, 1) do
    Enum.reduce_while(1..limit, {:error, :exhausted}, fn attempt, acc ->
      result = fun.()

      if predicate.(result) do
        {:halt, {:ok, result}}
      else
        Logger.debug("[RetryLogic] retry_until attempt #{attempt}/#{limit} did not satisfy predicate")
        {:cont, acc}
      end
    end)
  end

  @doc """
  Returns the calculated delay (in ms) for a given attempt number,
  using the current configuration's backoff settings.
  """
  @spec delay_for_attempt(pos_integer()) :: non_neg_integer()
  def delay_for_attempt(attempt) when is_integer(attempt) and attempt >= 1 do
    base = Application.fetch_env!(:retry_logic, :base_delay_ms)
    factor = Application.fetch_env!(:retry_logic, :backoff_factor)
    round(base * :math.pow(factor, attempt - 1))
  end

  # --- Private helpers ---

  defp do_retry(_fun, max, _base, _factor, _jitter, attempt) when attempt > max do
    {:error, :max_attempts_reached}
  end

  defp do_retry(fun, max, base, factor, jitter, attempt) do
    case fun.() do
      {:ok, _} = success ->
        Logger.debug("[RetryLogic] Succeeded on attempt #{attempt}/#{max}")
        success

      {:error, reason} = _failure ->
        delay = calculate_delay(base, factor, attempt, jitter)

        Logger.warning(
          "[RetryLogic] Attempt #{attempt}/#{max} failed: #{inspect(reason)}. " <>
            "Retrying in #{delay}ms…"
        )

        Process.sleep(delay)
        do_retry(fun, max, base, factor, jitter, attempt + 1)
    end
  end

  defp calculate_delay(base_ms, factor, attempt, add_jitter) do
    raw = round(base_ms * :math.pow(factor, attempt - 1))

    if add_jitter do
      jitter_range = max(div(raw, 4), 1)
      raw + :rand.uniform(jitter_range)
    else
      raw
    end
  end
end
```
