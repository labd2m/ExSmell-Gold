```elixir
defmodule PaymentGateway do
  @moduledoc """
  Processes payment submissions across multiple payment rails.
  """

  alias PaymentGateway.{
    CardChargeRequest,
    WireTransferRequest,
    VoucherRedemptionRequest,
    StripeClient,
    BankingAPI,
    Repo,
    Ledger
  }

  @card_fee_rate 0.029
  @card_fee_fixed 0.30
  @wire_processing_days 3

  @doc """
  Submits a payment request to the appropriate payment rail.

  ## Examples

      iex> PaymentGateway.submit(%CardChargeRequest{amount: 99.99, currency: "USD"})
      {:ok, %{transaction_id: "txn_abc", status: :captured}}

  """


  def submit(%CardChargeRequest{
        amount: amount,
        currency: currency,
        card_token: card_token,
        customer_id: customer_id,
        idempotency_key: idempotency_key
      })
      when is_float(amount) and amount > 0.0 do
    fee = Float.round(amount * @card_fee_rate + @card_fee_fixed, 2)
    net_amount = Float.round(amount - fee, 2)

    stripe_params = %{
      amount: trunc(amount * 100),
      currency: String.downcase(currency),
      source: card_token,
      metadata: %{customer_id: customer_id}
    }

    with {:ok, charge} <- StripeClient.create_charge(stripe_params, idempotency_key) do
      Ledger.record_payment(%{
        customer_id: customer_id,
        gross: amount,
        fee: fee,
        net: net_amount,
        currency: currency,
        provider: :stripe,
        provider_ref: charge["id"],
        status: :captured
      })

      {:ok, %{transaction_id: charge["id"], status: :captured, fee: fee}}
    end
  end

  # initiates an international bank wire transfer
  def submit(%WireTransferRequest{
        amount: amount,
        currency: currency,
        beneficiary_iban: iban,
        beneficiary_name: name,
        reference: reference,
        customer_id: customer_id
      }) do
    wire_params = %{
      amount: amount,
      currency: currency,
      beneficiary: %{iban: iban, name: name},
      reference: reference,
      processing_days: @wire_processing_days
    }

    with :ok <- BankingAPI.validate_iban(iban),
         {:ok, wire} <- BankingAPI.initiate_wire(wire_params) do
      expected_settlement = Date.add(Date.utc_today(), @wire_processing_days)

      Repo.insert_wire_transfer(%{
        customer_id: customer_id,
        wire_id: wire.id,
        amount: amount,
        currency: currency,
        beneficiary_iban: iban,
        status: :pending,
        expected_settlement_date: expected_settlement
      })

      {:ok, %{wire_id: wire.id, status: :pending, expected_settlement: expected_settlement}}
    else
      {:error, :invalid_iban} -> {:error, :invalid_beneficiary}
      {:error, reason} -> {:error, reason}
    end
  end

  # redeems a store credit voucher against an order balance
  def submit(%VoucherRedemptionRequest{
        voucher_code: code,
        order_id: order_id,
        customer_id: customer_id
      }) do
    with {:ok, voucher} <- Repo.find_voucher(code),
         :active <- voucher.status,
         true <- voucher.customer_id == customer_id or voucher.transferable,
         {:ok, order} <- Repo.find_order(order_id),
         credit <- min(voucher.balance, order.outstanding_amount),
         {:ok, _} <- Repo.apply_voucher_to_order(order_id, voucher.id, credit),
         {:ok, _} <- Repo.deduct_voucher_balance(voucher.id, credit) do
      Ledger.record_payment(%{
        customer_id: customer_id,
        gross: credit,
        fee: 0.0,
        net: credit,
        currency: voucher.currency,
        provider: :voucher,
        provider_ref: code,
        status: :applied
      })

      {:ok, %{credited: credit, voucher_remaining: voucher.balance - credit}}
    else
      status when is_atom(status) -> {:error, :voucher_not_active}
      false -> {:error, :voucher_not_transferable}
      {:error, reason} -> {:error, reason}
    end
  end

end
```
