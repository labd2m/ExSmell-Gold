```elixir
defmodule Resilience.RetryPolicy do
  @moduledoc """
  Executes a zero-arity function with configurable retry semantics:
  exponential backoff, full jitter, a maximum attempt ceiling, and
  a caller-supplied retryable? predicate for selective retries.
  """

  @type policy :: %{
          max_attempts: pos_integer(),
          base_delay_ms: pos_integer(),
          max_delay_ms: pos_integer(),
          jitter: boolean(),
          retryable?: (term() -> boolean())
        }

  @type retry_result(t) :: {:ok, t} | {:error, term()}

  @default_policy %{
    max_attempts: 3,
    base_delay_ms: 200,
    max_delay_ms: 5_000,
    jitter: true,
    retryable?: fn _ -> true end
  }

  @spec run((-> retry_result(term())), map()) :: retry_result(term())
  def run(fun, policy_overrides \\ %{}) when is_function(fun, 0) do
    policy = Map.merge(@default_policy, policy_overrides)
    attempt(fun, policy, 1)
  end

  @spec run_on_error((-> retry_result(term())), [atom()], map()) :: retry_result(term())
  def run_on_error(fun, retryable_reasons, policy_overrides \\ %{})
      when is_function(fun, 0) and is_list(retryable_reasons) do
    policy =
      Map.merge(@default_policy, policy_overrides)
      |> Map.put(:retryable?, fn reason -> reason in retryable_reasons end)

    attempt(fun, policy, 1)
  end

  @spec attempt((-> retry_result(term())), policy(), pos_integer()) :: retry_result(term())
  defp attempt(fun, policy, attempt_number) do
    case fun.() do
      {:ok, _} = success ->
        success

      {:error, reason} = error ->
        if should_retry?(reason, attempt_number, policy) do
          delay = compute_delay(attempt_number, policy)
          Process.sleep(delay)
          attempt(fun, policy, attempt_number + 1)
        else
          error
        end
    end
  end

  @spec should_retry?(term(), pos_integer(), policy()) :: boolean()
  defp should_retry?(reason, attempt_number, policy) do
    attempt_number < policy.max_attempts and policy.retryable?.(reason)
  end

  @spec compute_delay(pos_integer(), policy()) :: non_neg_integer()
  defp compute_delay(attempt_number, %{base_delay_ms: base, max_delay_ms: max, jitter: jitter}) do
    exponential = min(base * :math.pow(2, attempt_number - 1) |> round(), max)

    if jitter do
      :rand.uniform(exponential)
    else
      exponential
    end
  end

  @spec with_telemetry((-> retry_result(term())), atom(), map()) :: retry_result(term())
  def with_telemetry(fun, event_name, policy_overrides \\ %{}) when is_atom(event_name) do
    start = System.monotonic_time()
    attempt_count = :counters.new(1, [:atomics])

    instrumented = fn ->
      :counters.add(attempt_count, 1, 1)
      fun.()
    end

    result = run(instrumented, policy_overrides)
    duration = System.monotonic_time() - start
    attempts = :counters.get(attempt_count, 1)

    :telemetry.execute(
      [:retry_policy, event_name],
      %{duration: duration, attempts: attempts},
      %{success: match?({:ok, _}, result)}
    )

    result
  end
end
```
