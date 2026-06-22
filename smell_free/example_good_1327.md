```elixir
defmodule Resilience.Retry do
  @moduledoc """
  Executes a zero-arity function with configurable retry behaviour including
  exponential backoff and randomised jitter.

  Retry policies are described by typed structs to prevent configuration
  drift when the same policy is applied across multiple call sites.
  """

  alias Resilience.Retry.{Policy, Attempt, RetryResult}

  require Logger

  @doc """
  Runs `fun` according to the given `Policy`, retrying on failure.

  Returns `{:ok, value}` on success or `{:error, last_reason}` after
  exhausting all attempts.
  """
  @spec run((() -> {:ok, term()} | {:error, term()}), Policy.t()) ::
          {:ok, term()} | {:error, term()}
  def run(fun, %Policy{} = policy) when is_function(fun, 0) do
    execute(fun, policy, 1)
  end

  defp execute(fun, %Policy{max_attempts: max} = policy, attempt) do
    case fun.() do
      {:ok, value} ->
        {:ok, value}

      {:error, reason} when attempt >= max ->
        Logger.warning("retry exhausted after #{attempt} attempt(s): #{inspect(reason)}")
        {:error, reason}

      {:error, reason} ->
        delay = compute_delay(policy, attempt)
        Logger.debug("attempt #{attempt} failed, retrying in #{delay}ms: #{inspect(reason)}")
        Process.sleep(delay)
        execute(fun, policy, attempt + 1)
    end
  rescue
    err when is_exception(err) ->
      reason = Exception.message(err)

      if attempt < policy.max_attempts do
        delay = compute_delay(policy, attempt)
        Logger.debug("attempt #{attempt} raised, retrying in #{delay}ms: #{reason}")
        Process.sleep(delay)
        execute(fun, policy, attempt + 1)
      else
        Logger.warning("retry exhausted after #{attempt} attempt(s): #{reason}")
        {:error, reason}
      end
  end

  defp compute_delay(%Policy{base_delay_ms: base, max_delay_ms: max_delay, jitter: jitter}, attempt) do
    exponential = min(base * :math.pow(2, attempt - 1) |> round(), max_delay)

    if jitter do
      jitter_amount = :rand.uniform(div(exponential, 2))
      min(exponential + jitter_amount, max_delay)
    else
      exponential
    end
  end
end

defmodule Resilience.Retry.Policy do
  @moduledoc "Typed retry policy configuration."

  @enforce_keys [:max_attempts]
  defstruct [:max_attempts, base_delay_ms: 100, max_delay_ms: 30_000, jitter: true]

  @type t :: %__MODULE__{
          max_attempts: pos_integer(),
          base_delay_ms: pos_integer(),
          max_delay_ms: pos_integer(),
          jitter: boolean()
        }

  @doc """
  Creates a policy with a fixed number of attempts and default exponential backoff.
  """
  @spec new(pos_integer(), keyword()) :: t()
  def new(max_attempts, opts \\ []) when is_integer(max_attempts) and max_attempts > 0 do
    %__MODULE__{
      max_attempts: max_attempts,
      base_delay_ms: Keyword.get(opts, :base_delay_ms, 100),
      max_delay_ms: Keyword.get(opts, :max_delay_ms, 30_000),
      jitter: Keyword.get(opts, :jitter, true)
    }
  end

  @doc "A policy suitable for idempotent network calls: 3 attempts, 250ms base, jitter on."
  @spec for_network() :: t()
  def for_network, do: new(3, base_delay_ms: 250, max_delay_ms: 5_000)

  @doc "A policy suitable for database operations: 5 attempts, 100ms base, no jitter."
  @spec for_database() :: t()
  def for_database, do: new(5, base_delay_ms: 100, max_delay_ms: 2_000, jitter: false)

  @doc "A conservative policy for critical operations: 8 attempts, 500ms base, jitter on."
  @spec for_critical() :: t()
  def for_critical, do: new(8, base_delay_ms: 500, max_delay_ms: 60_000)
end

defmodule Resilience.Retry.Attempt do
  @moduledoc false

  @enforce_keys [:number, :started_at]
  defstruct [:number, :started_at, :result, :delay_ms]

  @type t :: %__MODULE__{}
end

defmodule Resilience.Retry.RetryResult do
  @moduledoc false

  @enforce_keys [:succeeded, :total_attempts, :final_result]
  defstruct [:succeeded, :total_attempts, :final_result, :elapsed_ms]

  @type t :: %__MODULE__{}
end
```
