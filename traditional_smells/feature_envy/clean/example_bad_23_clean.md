```elixir
defmodule Payments.Transaction do
  @moduledoc "Represents a completed payment transaction."

  defstruct [
    :id,
    :customer_id,
    :gateway,
    :amount,
    :currency,
    :fee,
    :status,
    :refunded_amount,
    :refund_policy,
    :charged_at,
    :dispute_opened
  ]

  def get!(id) do
    %__MODULE__{
      id: id,
      customer_id: "CUST-301",
      gateway: :stripe,
      amount: Decimal.new("199.99"),
      currency: "USD",
      fee: Decimal.new("6.20"),
      status: :captured,
      refunded_amount: Decimal.new("0.00"),
      refund_policy: :standard,
      charged_at: ~U[2024-02-20 15:00:00Z],
      dispute_opened: false
    }
  end

  def net_charged(%__MODULE__{amount: amount, fee: fee}) do
    Decimal.sub(amount, fee)
  end

  def refundable?(%__MODULE__{status: :captured, dispute_opened: false}), do: true
  def refundable?(_), do: false

  def partial_refund_cap(%__MODULE__{refund_policy: :standard, amount: amount}) do
    Decimal.mult(amount, Decimal.new("0.50"))
  end
  def partial_refund_cap(%__MODULE__{amount: amount}), do: amount

  def days_since_charge(%__MODULE__{charged_at: charged_at}) do
    DateTime.diff(DateTime.utc_now(), charged_at, :day)
  end

  def already_refunded?(%__MODULE__{refunded_amount: r}) do
    Decimal.gt?(r, Decimal.new("0.00"))
  end
end

defmodule Payments.RefundRequest do
  @moduledoc "A structured refund request ready for gateway submission."

  defstruct [:transaction_id, :amount, :currency, :reason, :partial]
end

defmodule Payments.RefundProcessor do
  @moduledoc """
  Handles the end-to-end refund workflow: validates eligibility,
  computes the refundable amount, and submits to the payment gateway.
  """

  alias Payments.{Transaction, RefundRequest}
  require Logger

  @refund_window_days 60

  @doc """
  Initiates a refund for the given transaction ID and reason.
  Returns `{:ok, RefundRequest.t()}` or `{:error, reason}`.
  """
  def initiate(transaction_id, reason) do
    txn = Transaction.get!(transaction_id)

    cond do
      not Transaction.refundable?(txn) ->
        {:error, :not_refundable}

      Transaction.days_since_charge(txn) > @refund_window_days ->
        {:error, :refund_window_expired}

      true ->
        amount = calculate_refund_amount(transaction_id)
        request = %RefundRequest{
          transaction_id: transaction_id,
          amount:         amount,
          currency:       txn.currency,
          reason:         reason,
          partial:        Transaction.already_refunded?(txn)
        }
        submit(request)
    end
  end

  defp calculate_refund_amount(transaction_id) do
    txn        = Transaction.get!(transaction_id)
    net        = Transaction.net_charged(txn)
    cap        = Transaction.partial_refund_cap(txn)
    days       = Transaction.days_since_charge(txn)
    refundable = Transaction.refundable?(txn)

    base =
      if refundable do
        Decimal.min(net, cap)
      else
        Decimal.new("0.00")
      end

    adjusted =
      if days > 30 do
        Decimal.mult(base, Decimal.new("0.75"))
      else
        base
      end

    Decimal.round(adjusted, 2)
  end

  defp submit(%RefundRequest{} = request) do
    Logger.info("Submitting refund #{request.amount} #{request.currency} for txn #{request.transaction_id}")
    {:ok, request}
  end
end
```
