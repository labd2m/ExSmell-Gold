```elixir
defmodule Resilience.Retry do
  @moduledoc """
  A composable retry utility with exponential back-off and jitter.
  Wraps any zero-arity function that returns `{:ok, result}` or
  `{:error, reason}`, retrying on transient errors up to the configured
  maximum attempts. The caller supplies an optional predicate to decide
  whether a given error is retryable, enabling fine-grained control without
  coupling this module to specific error domains.
  """

  require Logger

  @type retry_opts :: [
          max_attempts: pos_integer(),
          base_delay_ms: pos_integer(),
          max_delay_ms: pos_integer(),
          jitter: boolean(),
          retryable?: (term() -> boolean())
        ]

  @default_max_attempts 4
  @default_base_delay_ms 200
  @default_max_delay_ms 10_000
  @default_jitter true

  @doc """
  Executes `fun` with retry semantics defined by `opts`.

  ## Options

  * `:max_attempts` – Total attempts including the first (default: `4`).
  * `:base_delay_ms` – Starting delay in milliseconds (default: `200`).
  * `:max_delay_ms` – Upper bound for computed delay (default: `10_000`).
  * `:jitter` – Adds randomness to delays to avoid thundering herds (default: `true`).
  * `:retryable?` – One-argument predicate that receives the error term and
    returns `true` if the operation should be retried (default: always retry).

  Returns the first `{:ok, result}`, or the last `{:error, reason}` after
  all attempts are exhausted.
  """
  @spec run((() -> {:ok, term()} | {:error, term()}), retry_opts()) ::
          {:ok, term()} | {:error, term()}
  def run(fun, opts \\ []) when is_function(fun, 0) do
    config = build_config(opts)
    attempt(fun, config, 1)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp attempt(fun, config, attempt_number) do
    case fun.() do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} when attempt_number < config.max_attempts ->
        if config.retryable?.(reason) do
          delay = compute_delay(attempt_number, config)
          log_retry(reason, attempt_number, config.max_attempts, delay)
          Process.sleep(delay)
          attempt(fun, config, attempt_number + 1)
        else
          {:error, reason}
        end

      {:error, reason} ->
        Logger.warning("Retry exhausted after #{attempt_number} attempts",
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  defp compute_delay(attempt_number, %{base_delay_ms: base, max_delay_ms: cap, jitter: jitter}) do
    exponential = base * :math.pow(2, attempt_number - 1) |> trunc()
    capped = min(exponential, cap)

    if jitter do
      jitter_range = div(capped, 4)
      capped - jitter_range + :rand.uniform(jitter_range * 2 + 1) - 1
    else
      capped
    end
  end

  defp log_retry(reason, attempt, max, delay_ms) do
    Logger.info("Retrying after transient error",
      reason: inspect(reason),
      attempt: attempt,
      max_attempts: max,
      next_attempt_in_ms: delay_ms
    )
  end

  defp build_config(opts) do
    %{
      max_attempts: Keyword.get(opts, :max_attempts, @default_max_attempts),
      base_delay_ms: Keyword.get(opts, :base_delay_ms, @default_base_delay_ms),
      max_delay_ms: Keyword.get(opts, :max_delay_ms, @default_max_delay_ms),
      jitter: Keyword.get(opts, :jitter, @default_jitter),
      retryable?: Keyword.get(opts, :retryable?, fn _reason -> true end)
    }
  end
end
```
