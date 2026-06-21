```elixir
defmodule MyApp.Payments.RetryPolicy do
  @moduledoc """
  Determines whether a failed payment charge should be retried, and after
  what delay, based on the error code returned by the payment gateway.
  Transient infrastructure errors are retried with exponential back-off;
  hard declines (stolen card, fraud flags) are never retried.

  This module is purely functional — no processes, no side effects.
  """

  @max_attempts 4
  @base_delay_seconds 30

  @transient_codes ~w(
    insufficient_funds
    card_declined_temporarily
    do_not_honor
    try_again_later
    gateway_timeout
    processing_error
  )

  @permanent_codes ~w(
    card_stolen
    fraud_detected
    do_not_retry
    invalid_card_number
    card_expired
    account_closed
  )

  @type error_code :: String.t()
  @type attempt :: pos_integer()

  @type retry_decision ::
          {:retry, delay_seconds :: pos_integer()}
          | {:abandon, reason :: atom()}

  @doc """
  Returns a retry decision for a payment that failed with `error_code`
  on attempt number `attempt`.

  Decisions:
  * `{:retry, delay}` — wait `delay` seconds then retry.
  * `{:abandon, reason}` — do not retry; surface the failure to the customer.
  """
  @spec decide(error_code(), attempt()) :: retry_decision()
  def decide(error_code, attempt)
      when is_binary(error_code) and is_integer(attempt) and attempt >= 1 do
    cond do
      error_code in @permanent_codes ->
        {:abandon, :permanent_decline}

      attempt >= @max_attempts ->
        {:abandon, :max_attempts_exceeded}

      error_code in @transient_codes ->
        {:retry, backoff_seconds(attempt)}

      true ->
        {:abandon, :unknown_error_code}
    end
  end

  @doc """
  Returns the full retry schedule for a transient error as a list of
  `{attempt, delay_seconds}` pairs. Useful for operator dashboards.
  """
  @spec retry_schedule() :: [{attempt(), pos_integer()}]
  def retry_schedule do
    Enum.map(1..(@max_attempts - 1), fn attempt ->
      {attempt, backoff_seconds(attempt)}
    end)
  end

  @doc "Returns `true` when the error code is classified as permanent."
  @spec permanent_decline?(error_code()) :: boolean()
  def permanent_decline?(code) when is_binary(code), do: code in @permanent_codes

  @doc "Returns `true` when the error code is classified as transient."
  @spec transient_error?(error_code()) :: boolean()
  def transient_error?(code) when is_binary(code), do: code in @transient_codes

  @spec backoff_seconds(attempt()) :: pos_integer()
  defp backoff_seconds(attempt) do
    jitter = :rand.uniform(10)
    trunc(@base_delay_seconds * :math.pow(2, attempt - 1)) + jitter
  end
end
```
