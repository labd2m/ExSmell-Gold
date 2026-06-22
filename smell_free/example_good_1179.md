**File:** `example_good_1179.md`

```elixir
defmodule Retry.Policy do
  @moduledoc """
  Defines a retry policy including max attempt count, backoff strategy,
  optional jitter, and a predicate controlling which errors are retryable.
  """

  @enforce_keys [:max_attempts, :backoff]
  defstruct [
    :max_attempts,
    :backoff,
    jitter: false,
    retryable?: fn _ -> true end
  ]

  @type backoff ::
          {:constant, pos_integer()}
          | {:linear, pos_integer()}
          | {:exponential, pos_integer()}

  @type t :: %__MODULE__{
          max_attempts: pos_integer(),
          backoff: backoff(),
          jitter: boolean(),
          retryable?: (term() -> boolean())
        }

  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      max_attempts: Keyword.get(opts, :max_attempts, 3),
      backoff: Keyword.get(opts, :backoff, {:exponential, 100}),
      jitter: Keyword.get(opts, :jitter, false),
      retryable?: Keyword.get(opts, :retryable?, fn _ -> true end)
    }
  end

  @spec delay_ms(t(), pos_integer()) :: non_neg_integer()
  def delay_ms(%__MODULE__{backoff: backoff, jitter: jitter}, attempt) do
    base = compute_base_delay(backoff, attempt)
    if jitter, do: apply_jitter(base), else: base
  end

  defp compute_base_delay({:constant, ms}, _attempt), do: ms
  defp compute_base_delay({:linear, base_ms}, attempt), do: base_ms * attempt
  defp compute_base_delay({:exponential, base_ms}, attempt) do
    round(base_ms * :math.pow(2, attempt - 1))
  end

  defp apply_jitter(base_ms) do
    jitter = :rand.uniform(max(1, div(base_ms, 2)))
    base_ms + jitter
  end
end

defmodule Retry do
  @moduledoc """
  Executes a function with automatic retries according to a configured policy.
  Supports constant, linear, and exponential backoff with optional random jitter.
  """

  require Logger

  alias Retry.Policy

  @type retry_result(t) :: {:ok, t} | {:error, term()}

  @spec run(Policy.t(), (-> retry_result(term()))) :: retry_result(term())
  def run(%Policy{} = policy, func) when is_function(func, 0) do
    attempt(func, policy, 1)
  end

  defp attempt(func, %Policy{max_attempts: max} = policy, attempt_num)
       when attempt_num <= max do
    case func.() do
      {:ok, _} = success ->
        success

      {:error, reason} = failure ->
        if policy.retryable?.(reason) and attempt_num < max do
          delay = Policy.delay_ms(policy, attempt_num)
          Logger.debug("Attempt #{attempt_num}/#{max} failed: #{inspect(reason)}. Retrying in #{delay}ms.")
          Process.sleep(delay)
          attempt(func, policy, attempt_num + 1)
        else
          failure
        end
    end
  end

  defp attempt(_func, _policy, _attempt_num), do: {:error, :max_attempts_exceeded}
end

defmodule Retry.Policies do
  @moduledoc "A collection of pre-built retry policy configurations for common use cases."

  alias Retry.Policy

  @spec http_request() :: Policy.t()
  def http_request do
    Policy.new(
      max_attempts: 4,
      backoff: {:exponential, 250},
      jitter: true,
      retryable?: fn
        :timeout -> true
        :econnrefused -> true
        {:http_error, status} when status in [429, 500, 502, 503, 504] -> true
        _ -> false
      end
    )
  end

  @spec database_query() :: Policy.t()
  def database_query do
    Policy.new(
      max_attempts: 3,
      backoff: {:linear, 100},
      jitter: false,
      retryable?: fn
        :checkout_timeout -> true
        {:error, :connection_closed} -> true
        _ -> false
      end
    )
  end

  @spec external_api() :: Policy.t()
  def external_api do
    Policy.new(
      max_attempts: 5,
      backoff: {:exponential, 500},
      jitter: true,
      retryable?: fn
        :rate_limited -> true
        :service_unavailable -> true
        _ -> false
      end
    )
  end

  @spec no_retry() :: Policy.t()
  def no_retry do
    Policy.new(
      max_attempts: 1,
      backoff: {:constant, 0},
      retryable?: fn _ -> false end
    )
  end
end
```
