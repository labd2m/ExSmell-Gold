```elixir
defmodule Payments.Gateway.RetryPolicy do
  @moduledoc """
  Implements exponential backoff retry logic for payment gateway calls.
  Retries are bounded by max attempts and a total elapsed time cap.
  """

  @type attempt_result :: {:ok, term()} | {:error, :retryable | :fatal, term()}
  @type policy :: %{
          max_attempts: pos_integer(),
          base_delay_ms: pos_integer(),
          max_delay_ms: pos_integer(),
          max_total_ms: pos_integer()
        }

  @default_policy %{
    max_attempts: 4,
    base_delay_ms: 200,
    max_delay_ms: 8_000,
    max_total_ms: 30_000
  }

  @doc """
  Retries `fun` according to `policy` using exponential backoff.

  `fun` must return `{:ok, result}`, `{:error, :retryable, reason}`, or `{:error, :fatal, reason}`.
  Returns `{:ok, result}` on success, `{:error, reason}` after exhausting retries or on fatal error.
  """
  @spec with_retry((-> attempt_result()), policy()) :: {:ok, term()} | {:error, term()}
  def with_retry(fun, policy \\ @default_policy) when is_function(fun, 0) and is_map(policy) do
    start_ms = System.monotonic_time(:millisecond)
    do_retry(fun, policy, 1, start_ms)
  end

  defp do_retry(fun, policy, attempt, start_ms) do
    case fun.() do
      {:ok, _} = success ->
        success

      {:error, :fatal, reason} ->
        {:error, reason}

      {:error, :retryable, reason} ->
        elapsed = System.monotonic_time(:millisecond) - start_ms

        if attempt >= policy.max_attempts or elapsed >= policy.max_total_ms do
          {:error, reason}
        else
          delay = compute_delay(attempt, policy)
          Process.sleep(delay)
          do_retry(fun, policy, attempt + 1, start_ms)
        end
    end
  end

  defp compute_delay(attempt, policy) do
    jitter = :rand.uniform(100)
    raw_delay = policy.base_delay_ms * Integer.pow(2, attempt - 1) + jitter
    min(raw_delay, policy.max_delay_ms)
  end

  @doc """
  Returns the default retry policy.
  """
  @spec default_policy() :: policy()
  def default_policy, do: @default_policy

  @doc """
  Builds a custom policy, merging provided values over the defaults.

  ## Options
    - `:max_attempts` - max retry attempts
    - `:base_delay_ms` - initial backoff delay in milliseconds
    - `:max_delay_ms` - ceiling for computed delay
    - `:max_total_ms` - maximum total elapsed time before giving up
  """
  @spec build_policy(keyword()) :: {:ok, policy()} | {:error, String.t()}
  def build_policy(opts) when is_list(opts) do
    policy = Map.merge(@default_policy, Map.new(opts))

    cond do
      not is_integer(policy.max_attempts) or policy.max_attempts < 1 ->
        {:error, "max_attempts must be a positive integer"}

      not is_integer(policy.base_delay_ms) or policy.base_delay_ms < 1 ->
        {:error, "base_delay_ms must be a positive integer"}

      policy.max_delay_ms < policy.base_delay_ms ->
        {:error, "max_delay_ms must be >= base_delay_ms"}

      not is_integer(policy.max_total_ms) or policy.max_total_ms < 1 ->
        {:error, "max_total_ms must be a positive integer"}

      true ->
        {:ok, policy}
    end
  end
end
```
