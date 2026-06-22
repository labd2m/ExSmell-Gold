```elixir
defmodule Payments.Processor do
  @moduledoc """
  Orchestrates payment charge attempts against a pluggable gateway.
  Retries are handled with truncated exponential backoff up to a
  configurable maximum. All outcomes are returned as tagged tuples
  so callers can branch without exception handling.
  """

  alias Payments.{Charge, Gateway, RetryPolicy}

  @type charge_params :: %{
          amount_cents: pos_integer(),
          currency: String.t(),
          source_token: String.t(),
          idempotency_key: String.t()
        }

  @type charge_result ::
          {:ok, Charge.t()}
          | {:error, :declined, String.t()}
          | {:error, :gateway_unavailable}
          | {:error, :invalid_params}

  @doc """
  Attempts to charge the given params through the gateway.
  Transient gateway errors trigger retries per the supplied policy.
  """
  @spec charge(charge_params(), Gateway.t(), RetryPolicy.t()) :: charge_result()
  def charge(params, gateway, policy)
      when is_map(params) do
    with {:ok, validated} <- validate_params(params) do
      attempt_with_retry(validated, gateway, policy, 0)
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp attempt_with_retry(params, gateway, policy, attempt) do
    case Gateway.charge(gateway, params) do
      {:ok, charge} ->
        {:ok, charge}

      {:error, :declined, reason} ->
        {:error, :declined, reason}

      {:error, :transient} ->
        handle_transient(params, gateway, policy, attempt)

      {:error, _reason} ->
        {:error, :gateway_unavailable}
    end
  end

  defp handle_transient(_params, _gateway, policy, attempt)
       when attempt >= policy.max_attempts do
    {:error, :gateway_unavailable}
  end

  defp handle_transient(params, gateway, policy, attempt) do
    delay = RetryPolicy.backoff_ms(policy, attempt)
    Process.sleep(delay)
    attempt_with_retry(params, gateway, policy, attempt + 1)
  end

  defp validate_params(%{amount_cents: a, currency: c, source_token: s, idempotency_key: k})
       when is_integer(a) and a > 0 and is_binary(c) and is_binary(s) and is_binary(k) do
    {:ok, %{amount_cents: a, currency: c, source_token: s, idempotency_key: k}}
  end

  defp validate_params(_), do: {:error, :invalid_params}
end

defmodule Payments.RetryPolicy do
  @moduledoc "Defines retry limits and truncated exponential backoff parameters."

  @type t :: %__MODULE__{
          max_attempts: pos_integer(),
          base_delay_ms: pos_integer(),
          max_delay_ms: pos_integer()
        }

  defstruct max_attempts: 3, base_delay_ms: 200, max_delay_ms: 5_000

  @doc "Computes the backoff delay in milliseconds for a given attempt index."
  @spec backoff_ms(t(), non_neg_integer()) :: pos_integer()
  def backoff_ms(%__MODULE__{base_delay_ms: base, max_delay_ms: cap}, attempt) do
    calculated = base * Integer.pow(2, attempt)
    min(calculated, cap)
  end
end
```
