# File: `example_good_553.md`

```elixir
defmodule Network.RetryPolicy do
  @moduledoc """
  Composable retry policy builder for executing fallible operations
  with configurable backoff, jitter, and termination conditions.

  Policies are plain structs assembled via builder functions, then
  passed to `execute/2` or `execute!/2`. The policy itself holds no
  mutable state; all execution context is local to each call.
  """

  @enforce_keys [:max_attempts]
  defstruct [
    :max_attempts,
    base_delay_ms: 100,
    max_delay_ms: 30_000,
    backoff: :exponential,
    jitter: true,
    retryable?: &Network.RetryPolicy.default_retryable?/1
  ]

  @type t :: %__MODULE__{
          max_attempts: pos_integer(),
          base_delay_ms: pos_integer(),
          max_delay_ms: pos_integer(),
          backoff: :linear | :exponential | :constant,
          jitter: boolean(),
          retryable?: (term() -> boolean())
        }

  @type result :: {:ok, term()} | {:error, term()}

  @doc """
  Creates a new policy with the given maximum attempt count.
  """
  @spec new(pos_integer()) :: t()
  def new(max_attempts) when is_integer(max_attempts) and max_attempts > 0 do
    %__MODULE__{max_attempts: max_attempts}
  end

  @doc """
  Sets the base delay between retries in milliseconds.
  """
  @spec with_base_delay(t(), pos_integer()) :: t()
  def with_base_delay(%__MODULE__{} = policy, ms) when is_integer(ms) and ms > 0 do
    %{policy | base_delay_ms: ms}
  end

  @doc """
  Caps the maximum computed delay to `ms` milliseconds.
  """
  @spec with_max_delay(t(), pos_integer()) :: t()
  def with_max_delay(%__MODULE__{} = policy, ms) when is_integer(ms) and ms > 0 do
    %{policy | max_delay_ms: ms}
  end

  @doc """
  Sets the backoff strategy: `:exponential`, `:linear`, or `:constant`.
  """
  @spec with_backoff(t(), :exponential | :linear | :constant) :: t()
  def with_backoff(%__MODULE__{} = policy, strategy)
      when strategy in [:exponential, :linear, :constant] do
    %{policy | backoff: strategy}
  end

  @doc """
  Disables random jitter on computed delays.
  """
  @spec without_jitter(t()) :: t()
  def without_jitter(%__MODULE__{} = policy), do: %{policy | jitter: false}

  @doc """
  Sets a predicate that determines whether an error is retryable.
  Non-retryable errors are returned immediately.
  """
  @spec retryable_when(t(), (term() -> boolean())) :: t()
  def retryable_when(%__MODULE__{} = policy, pred) when is_function(pred, 1) do
    %{policy | retryable?: pred}
  end

  @doc """
  Executes `fun/0` according to `policy`, retrying on retryable errors.

  Returns `{:ok, value}` on success or `{:error, last_error}` after
  all attempts are exhausted.
  """
  @spec execute(t(), (-> result())) :: result()
  def execute(%__MODULE__{} = policy, fun) when is_function(fun, 0) do
    attempt(fun, policy, 1)
  end

  @doc """
  Like `execute/2` but raises on final failure.
  """
  @spec execute!(t(), (-> result())) :: term()
  def execute!(%__MODULE__{} = policy, fun) when is_function(fun, 0) do
    case execute(policy, fun) do
      {:ok, value} -> value
      {:error, reason} -> raise "RetryPolicy exhausted: #{inspect(reason)}"
    end
  end

  @doc false
  @spec default_retryable?(term()) :: boolean()
  def default_retryable?({:error, _}), do: true
  def default_retryable?(_), do: false

  defp attempt(fun, policy, attempt_number) do
    case fun.() do
      {:ok, _value} = ok ->
        ok

      {:error, reason} = error ->
        if attempt_number >= policy.max_attempts or not policy.retryable?.(error) do
          error
        else
          delay = compute_delay(policy, attempt_number)
          Process.sleep(delay)
          attempt(fun, policy, attempt_number + 1)
        end
    end
  rescue
    exception ->
      error = {:error, {:exception, Exception.message(exception)}}

      if not policy.retryable?.(error) or 1 >= policy.max_attempts do
        error
      else
        Process.sleep(compute_delay(policy, 1))
        attempt(fun, policy, 2)
      end
  end

  defp compute_delay(policy, attempt_number) do
    base =
      case policy.backoff do
        :exponential -> min(policy.base_delay_ms * Integer.pow(2, attempt_number - 1), policy.max_delay_ms)
        :linear -> min(policy.base_delay_ms * attempt_number, policy.max_delay_ms)
        :constant -> policy.base_delay_ms
      end

    if policy.jitter do
      jitter = :rand.uniform(div(base, 4) + 1)
      min(base + jitter, policy.max_delay_ms)
    else
      base
    end
  end
end
```
