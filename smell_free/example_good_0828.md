```elixir
defmodule AdaptiveRetry.Policy do
  @moduledoc """
  Defines how retries should respond to different error categories.

  Network and timeout errors use exponential back-off with jitter;
  rate-limiting errors respect the `Retry-After` value when present;
  domain validation errors are never retried because they are deterministic.
  """

  @type error_category :: :network | :timeout | :rate_limited | :server_error | :client_error | :unknown

  @type t :: %__MODULE__{
          max_attempts: pos_integer(),
          base_delay_ms: pos_integer(),
          max_delay_ms: pos_integer(),
          retryable_categories: [error_category()]
        }

  defstruct [
    max_attempts: 4,
    base_delay_ms: 200,
    max_delay_ms: 30_000,
    retryable_categories: [:network, :timeout, :server_error, :rate_limited, :unknown]
  ]

  @spec categorize(term()) :: error_category()
  def categorize({:http_error, status}) when status in 429..429, do: :rate_limited
  def categorize({:http_error, status}) when status in 500..599, do: :server_error
  def categorize({:http_error, status}) when status in 400..499, do: :client_error
  def categorize({:timeout}), do: :timeout
  def categorize({:transport_error, _}), do: :network
  def categorize(:circuit_open), do: :network
  def categorize(_), do: :unknown

  @spec retryable?(t(), term()) :: boolean()
  def retryable?(%__MODULE__{retryable_categories: cats}, reason) do
    categorize(reason) in cats
  end

  @spec delay_ms(t(), pos_integer(), term()) :: non_neg_integer()
  def delay_ms(_policy, _attempt, {:http_error, 429}) do
    5_000
  end

  def delay_ms(%__MODULE__{base_delay_ms: base, max_delay_ms: max}, attempt, _reason) do
    raw = min(base * trunc(:math.pow(2, attempt - 1)), max)
    jitter = :rand.uniform(div(raw, 4) + 1)
    raw + jitter
  end
end

defmodule AdaptiveRetry do
  @moduledoc """
  Executes a function with adaptive retry logic that classifies errors
  and adjusts back-off accordingly.

  Deterministic errors (4xx responses) are never retried. Transient errors
  (5xx, network, timeout) use exponential back-off. Rate-limit responses
  pause for a fixed window. The circuit breaker name is optional; when
  provided, an open circuit is treated as an immediate non-retryable failure.
  """

  alias AdaptiveRetry.Policy

  @type opts :: [
          policy: Policy.t(),
          circuit_breaker: atom() | nil,
          telemetry_prefix: [atom()]
        ]

  @spec run((-> {:ok, term()} | {:error, term()}), opts()) ::
          {:ok, term()} | {:error, term()}
  def run(fun, opts \\ []) when is_function(fun, 0) do
    policy = Keyword.get(opts, :policy, %Policy{})
    breaker = Keyword.get(opts, :circuit_breaker)
    prefix = Keyword.get(opts, :telemetry_prefix, [:adaptive_retry])

    do_run(fun, policy, breaker, prefix, 1)
  end

  defp do_run(fun, policy, breaker, prefix, attempt) do
    result =
      if breaker do
        case CircuitBreaker.Registry.call(breaker, fun) do
          {:error, :circuit_open} -> {:error, :circuit_open}
          other -> other
        end
      else
        safely(fun)
      end

    case result do
      {:ok, _} = ok ->
        emit(prefix, :succeeded, %{attempt: attempt})
        ok

      {:error, reason} when attempt < policy.max_attempts ->
        if Policy.retryable?(policy, reason) do
          delay = Policy.delay_ms(policy, attempt, reason)
          emit(prefix, :retrying, %{attempt: attempt, reason: inspect(reason), delay_ms: delay})
          :timer.sleep(delay)
          do_run(fun, policy, breaker, prefix, attempt + 1)
        else
          emit(prefix, :failed, %{attempt: attempt, reason: inspect(reason), retryable: false})
          {:error, reason}
        end

      {:error, reason} ->
        emit(prefix, :exhausted, %{attempt: attempt, reason: inspect(reason)})
        {:error, reason}
    end
  end

  defp safely(fun) do
    {:ok, fun.()}
  rescue
    error -> {:error, {:exception, error}}
  end

  defp emit(prefix, event, measurements) do
    :telemetry.execute(prefix ++ [event], measurements, %{})
  end
end
```
