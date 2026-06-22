```elixir
defmodule Fintech.Payments.Gateway do
  @moduledoc """
  Handles payment authorization and capture flows against an external
  payment provider. All public functions return tagged tuples so callers
  can pattern-match results without relying on exception handling.
  """

  alias Fintech.Payments.{ChargeRequest, ChargeResult, RefundResult}
  alias Fintech.HTTP.Client

  @type charge_opts :: [idempotency_key: String.t(), timeout_ms: pos_integer()]

  @doc """
  Authorizes and captures a charge for the given request.

  Returns `{:ok, ChargeResult.t()}` on success or `{:error, reason}` on failure.
  """
  @spec charge(ChargeRequest.t(), charge_opts()) ::
          {:ok, ChargeResult.t()} | {:error, :declined | :timeout | :invalid_request}
  def charge(%ChargeRequest{} = request, opts \\ []) do
    with :ok <- validate_charge_request(request),
         {:ok, payload} <- build_charge_payload(request, opts),
         {:ok, response} <- Client.post("/charges", payload, opts),
         {:ok, result} <- parse_charge_response(response) do
      {:ok, result}
    end
  end

  @doc """
  Issues a full or partial refund against a previously captured charge.
  """
  @spec refund(String.t(), pos_integer()) ::
          {:ok, RefundResult.t()} | {:error, :not_found | :already_refunded | :invalid_amount}
  def refund(charge_id, amount_cents)
      when is_binary(charge_id) and is_integer(amount_cents) and amount_cents > 0 do
    with {:ok, response} <- Client.post("/refunds", %{charge_id: charge_id, amount: amount_cents}),
         {:ok, result} <- parse_refund_response(response) do
      {:ok, result}
    end
  end

  def refund(_charge_id, _amount_cents), do: {:error, :invalid_amount}

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @spec validate_charge_request(ChargeRequest.t()) :: :ok | {:error, :invalid_request}
  defp validate_charge_request(%ChargeRequest{amount_cents: amount, currency: currency})
       when is_integer(amount) and amount > 0 and is_binary(currency) do
    :ok
  end

  defp validate_charge_request(_), do: {:error, :invalid_request}

  @spec build_charge_payload(ChargeRequest.t(), charge_opts()) ::
          {:ok, map()} | {:error, :invalid_request}
  defp build_charge_payload(%ChargeRequest{} = req, opts) do
    payload = %{
      amount: req.amount_cents,
      currency: req.currency,
      source: req.payment_method_id,
      idempotency_key: Keyword.get(opts, :idempotency_key, generate_idempotency_key())
    }

    {:ok, payload}
  end

  @spec parse_charge_response(map()) :: {:ok, ChargeResult.t()} | {:error, :declined | :timeout}
  defp parse_charge_response(%{"status" => "succeeded", "id" => id, "amount" => amount}) do
    {:ok, %ChargeResult{id: id, amount_cents: amount, status: :succeeded}}
  end

  defp parse_charge_response(%{"status" => "declined"}) do
    {:error, :declined}
  end

  defp parse_charge_response(%{"error" => "timeout"}) do
    {:error, :timeout}
  end

  @spec parse_refund_response(map()) ::
          {:ok, RefundResult.t()} | {:error, :not_found | :already_refunded}
  defp parse_refund_response(%{"status" => "succeeded", "id" => id}) do
    {:ok, %RefundResult{id: id, status: :succeeded}}
  end

  defp parse_refund_response(%{"error" => "charge_not_found"}) do
    {:error, :not_found}
  end

  defp parse_refund_response(%{"error" => "already_refunded"}) do
    {:error, :already_refunded}
  end

  @spec generate_idempotency_key() :: String.t()
  defp generate_idempotency_key do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
```
