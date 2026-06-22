```elixir
defmodule Fincore.Payments.Processor do
  @moduledoc """
  Orchestrates payment authorization and capture for checkout flows.

  Each payment attempt is validated at the boundary, enriched with idempotency
  metadata, and dispatched through a pluggable gateway adapter.
  """

  alias Fincore.Payments.{Authorization, Capture, GatewayAdapter, Receipt}
  alias Fincore.Accounts.Wallet

  @type payment_params :: %{
          amount_cents: pos_integer(),
          currency: String.t(),
          source_token: String.t(),
          idempotency_key: String.t()
        }

  @type result(t) :: {:ok, t} | {:error, String.t()}

  @doc """
  Authorizes and captures a payment in a single pass.

  Returns `{:ok, receipt}` on success or `{:error, reason}` if authorization
  or capture fails.
  """
  @spec charge(Wallet.t(), payment_params(), keyword()) :: result(Receipt.t())
  def charge(%Wallet{} = wallet, params, opts \\ []) do
    gateway = Keyword.get(opts, :gateway, GatewayAdapter.default())

    with {:ok, validated} <- validate_params(params),
         {:ok, auth} <- Authorization.request(wallet, validated, gateway),
         {:ok, capture} <- Capture.execute(auth, gateway),
         {:ok, receipt} <- Receipt.build(wallet, capture) do
      {:ok, receipt}
    end
  end

  @doc """
  Refunds a previously captured payment up to its original amount.
  """
  @spec refund(Receipt.t(), pos_integer(), keyword()) :: result(Receipt.t())
  def refund(%Receipt{} = receipt, amount_cents, opts \\ []) when is_integer(amount_cents) and amount_cents > 0 do
    gateway = Keyword.get(opts, :gateway, GatewayAdapter.default())

    with :ok <- check_refundable(receipt, amount_cents),
         {:ok, refund_record} <- gateway.refund(receipt.capture_id, amount_cents),
         {:ok, updated} <- Receipt.mark_refunded(receipt, refund_record) do
      {:ok, updated}
    end
  end

  # --- private helpers ---

  @spec validate_params(map()) :: result(payment_params())
  defp validate_params(%{amount_cents: a, currency: c, source_token: s, idempotency_key: k})
       when is_integer(a) and a > 0 and is_binary(c) and is_binary(s) and is_binary(k) do
    {:ok, %{amount_cents: a, currency: c, source_token: s, idempotency_key: k}}
  end

  defp validate_params(_), do: {:error, "invalid payment params"}

  @spec check_refundable(Receipt.t(), pos_integer()) :: :ok | {:error, String.t()}
  defp check_refundable(%Receipt{captured_cents: cap, refunded_cents: ref}, amount)
       when amount <= cap - ref,
       do: :ok

  defp check_refundable(_, _), do: {:error, "refund exceeds capturable balance"}
end
```
