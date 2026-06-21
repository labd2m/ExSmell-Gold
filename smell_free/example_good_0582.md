```elixir
defmodule Platform.Retry do
  @moduledoc """
  Pure-function retry logic with configurable backoff strategies and jitter.

  No processes are spawned; retries run synchronously in the caller's context.
  Strategies are composable: base delay, multiplier, jitter, and maximum delay
  are all independently tunable. Specific error reasons can be excluded from
  retry eligibility via the `:halt_on` option.
  """

  @type strategy :: :exponential | :linear | :constant
  @type result :: {:ok, term()} | {:error, term()}
  @type retry_opts :: [
          strategy: strategy(),
          max_attempts: pos_integer(),
          base_delay_ms: pos_integer(),
          max_delay_ms: pos_integer(),
          multiplier: number(),
          jitter: boolean(),
          halt_on: [term()]
        ]

  @defaults [
    strategy: :exponential,
    max_attempts: 3,
    base_delay_ms: 100,
    max_delay_ms: 30_000,
    multiplier: 2,
    jitter: true,
    halt_on: []
  ]

  @doc """
  Retries `fun` up to `max_attempts` times on `{:error, _}` results.
  Sleeps between attempts according to the configured backoff strategy.
  Returns the last result if all attempts are exhausted.
  """
  @spec with_retry((-> result()), retry_opts()) :: result()
  def with_retry(fun, opts \\ []) when is_function(fun, 0) do
    config = Keyword.merge(@defaults, opts)
    attempt(fun, config, 1)
  end

  @doc "Computes the delay in milliseconds for a given attempt number and config."
  @spec delay_for(pos_integer(), retry_opts()) :: non_neg_integer()
  def delay_for(attempt, opts \\ []) when is_integer(attempt) and attempt >= 1 do
    config = Keyword.merge(@defaults, opts)
    compute_delay(attempt, config)
  end

  defp attempt(fun, config, current_attempt) do
    result = fun.()

    case result do
      {:ok, _} ->
        result

      {:error, reason} when current_attempt >= config[:max_attempts] ->
        result

      {:error, reason} ->
        if reason in config[:halt_on] do
          result
        else
          delay = compute_delay(current_attempt, config)
          Process.sleep(delay)
          attempt(fun, config, current_attempt + 1)
        end
    end
  end

  defp compute_delay(attempt, config) do
    base = config[:base_delay_ms]
    max_ms = config[:max_delay_ms]
    multiplier = config[:multiplier]
    jitter? = config[:jitter]

    raw =
      case config[:strategy] do
        :exponential -> trunc(base * :math.pow(multiplier, attempt - 1))
        :linear -> base * attempt
        :constant -> base
      end

    capped = min(raw, max_ms)
    if jitter?, do: add_jitter(capped), else: capped
  end

  defp add_jitter(delay_ms) when delay_ms > 0 do
    jitter = :rand.uniform(max(div(delay_ms, 4), 1))
    delay_ms + jitter
  end

  defp add_jitter(0), do: 0
end
```
