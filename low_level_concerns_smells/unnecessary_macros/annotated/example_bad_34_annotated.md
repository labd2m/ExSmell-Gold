# Annotated Example – Unnecessary Macros

| Field | Value |
|---|---|
| **Smell name** | Unnecessary macros |
| **Expected smell location** | `Payments.RetryPolicy` module, `backoff_delay/2` macro |
| **Affected function(s)** | `backoff_delay/2` |
| **Short explanation** | `backoff_delay/2` computes an exponential back-off delay from two integer arguments. The computation is entirely arithmetic on runtime values; a regular function would be simpler and just as efficient with no need for `quote`/`unquote`. |

```elixir
defmodule Payments.RetryPolicy do
  @moduledoc """
  Defines retry behaviour for failed payment transactions, including
  exponential back-off, jitter, and maximum attempt limits.
  """

  @base_delay_ms 500
  @max_delay_ms 30_000
  @max_attempts 5
  @jitter_factor 0.2

  # VALIDATION: SMELL START - Unnecessary macros
  # VALIDATION: This is a smell because `backoff_delay/2` computes a
  # numeric value from two integer runtime inputs. The formula is
  # straightforward arithmetic — no AST manipulation is needed. Defining
  # it as a macro forces every caller to `require` the module, adds noise
  # to the implementation, and provides no compile-time benefit at all.
  defmacro backoff_delay(attempt, base_ms) do
    quote do
      raw = unquote(base_ms) * :math.pow(2, unquote(attempt) - 1)
      capped = min(raw, unquote(@max_delay_ms))
      jitter = capped * unquote(@jitter_factor) * :rand.uniform()
      round(capped + jitter)
    end
  end
  # VALIDATION: SMELL END

  def should_retry?(attempt, error) do
    attempt < @max_attempts and retryable_error?(error)
  end

  defp retryable_error?(:timeout), do: true
  defp retryable_error?(:connection_refused), do: true
  defp retryable_error?(:service_unavailable), do: true
  defp retryable_error?({:http_error, 429}), do: true
  defp retryable_error?({:http_error, 503}), do: true
  defp retryable_error?(_), do: false

  def next_attempt_at(attempt) do
    require Payments.RetryPolicy
    delay = Payments.RetryPolicy.backoff_delay(attempt, @base_delay_ms)
    DateTime.add(DateTime.utc_now(), delay, :millisecond)
  end

  def schedule_retry(transaction_id, attempt, error) do
    require Payments.RetryPolicy

    if should_retry?(attempt, error) do
      delay = Payments.RetryPolicy.backoff_delay(attempt, @base_delay_ms)

      %{
        transaction_id: transaction_id,
        attempt: attempt + 1,
        retry_at: DateTime.add(DateTime.utc_now(), delay, :millisecond),
        delay_ms: delay
      }
    else
      {:give_up, %{transaction_id: transaction_id, attempts: attempt}}
    end
  end

  def retry_schedule(transaction_id) do
    require Payments.RetryPolicy

    for attempt <- 1..@max_attempts do
      delay = Payments.RetryPolicy.backoff_delay(attempt, @base_delay_ms)

      %{
        attempt: attempt,
        delay_ms: delay,
        retry_at: DateTime.add(DateTime.utc_now(), delay * attempt, :millisecond)
      }
    end
    |> then(&%{transaction_id: transaction_id, schedule: &1})
  end

  def max_attempts, do: @max_attempts
  def base_delay_ms, do: @base_delay_ms

  def summarise_policy do
    %{
      max_attempts: @max_attempts,
      base_delay_ms: @base_delay_ms,
      max_delay_ms: @max_delay_ms,
      jitter_factor: @jitter_factor,
      strategy: :exponential_with_jitter
    }
  end
end
```
