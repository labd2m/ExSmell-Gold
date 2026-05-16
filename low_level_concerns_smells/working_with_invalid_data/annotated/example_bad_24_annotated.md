# Code Smell Annotation

- **Smell name:** Working with invalid data
- **Expected smell location:** `RefundProcessor.process/3`, where `refund_amount` is passed to `Decimal.compare/2`
- **Affected function(s):** `process/3`
- **Short explanation:** The `refund_amount` parameter is passed to `Decimal.compare/2` without first checking that it is either a `Decimal` struct, a number, or a valid string representation. If a caller passes an atom or a plain map, `Decimal.compare/2` (or the internal `Decimal.new/1` coercion it performs) raises a `Decimal.Error` or `FunctionClauseError` deep inside the Decimal library, hiding the fact that invalid data was accepted at the `process/3` boundary.

```elixir
defmodule MyApp.Payments.RefundProcessor do
  @moduledoc """
  Handles full and partial refund processing against previously settled
  transactions. Enforces refund eligibility windows, amount caps, and
  idempotency using refund reference identifiers.
  """

  require Logger

  alias MyApp.Payments.{TransactionStore, RefundLedger, Gateway, FraudGuard}
  alias MyApp.Accounts.Customer

  @max_refund_window_days 180
  @partial_refund_min Decimal.new("0.01")
  @max_refunds_per_transaction 5

  @type refund_opts :: [
          reason: String.t(),
          idempotency_key: String.t(),
          notify_customer: boolean(),
          internal_note: String.t() | nil
        ]

  @spec process(String.t(), term(), refund_opts()) ::
          {:ok, map()} | {:error, atom()}
  def process(transaction_id, refund_amount, opts \\ []) do
    reason = Keyword.get(opts, :reason, "customer_request")
    idempotency_key = Keyword.get(opts, :idempotency_key, generate_key())
    notify = Keyword.get(opts, :notify_customer, true)
    note = Keyword.get(opts, :internal_note)

    with {:ok, tx} <- TransactionStore.fetch(transaction_id),
         :ok <- check_refund_window(tx),
         :ok <- check_refund_count(transaction_id),
         {:ok, :new} <- check_idempotency(idempotency_key) do

      # VALIDATION: SMELL START - Working with invalid data
      # VALIDATION: This is a smell because `refund_amount` is passed directly to
      # VALIDATION: `Decimal.compare/2` without checking it is a Decimal, number,
      # VALIDATION: or valid numeric string. If a caller passes an atom or a map,
      # VALIDATION: the Decimal library raises an error deep inside its coercion
      # VALIDATION: logic with no reference to the `process/3` boundary where the
      # VALIDATION: invalid value was accepted.
      cmp = Decimal.compare(refund_amount, tx.amount)
      # VALIDATION: SMELL END

      if cmp == :gt do
        Logger.warning(
          "Refund amount #{refund_amount} exceeds transaction amount #{tx.amount} " <>
            "for transaction #{transaction_id}"
        )

        {:error, :refund_exceeds_original}
      else
        with :ok <- FraudGuard.check_refund(tx, refund_amount),
             {:ok, refund_tx} <-
               Gateway.refund(%{
                 original_transaction_id: transaction_id,
                 amount: refund_amount,
                 currency: tx.currency,
                 reason: reason
               }),
             :ok <-
               RefundLedger.record(%{
                 refund_id: refund_tx.id,
                 transaction_id: transaction_id,
                 amount: refund_amount,
                 reason: reason,
                 idempotency_key: idempotency_key,
                 note: note,
                 refunded_at: DateTime.utc_now()
               }) do
          Logger.info(
            "Refund processed: transaction=#{transaction_id} " <>
              "amount=#{refund_amount} refund_id=#{refund_tx.id}"
          )

          maybe_notify_customer(tx.customer_id, refund_amount, tx.currency, notify)
          {:ok, refund_tx}
        end
      end
    end
  end

  @spec refund_history(String.t()) :: {:ok, [map()]} | {:error, atom()}
  def refund_history(transaction_id) do
    RefundLedger.fetch_all(transaction_id)
  end

  @spec total_refunded(String.t()) :: {:ok, Decimal.t()} | {:error, atom()}
  def total_refunded(transaction_id) do
    with {:ok, refunds} <- RefundLedger.fetch_all(transaction_id) do
      total = Enum.reduce(refunds, Decimal.new("0"), fn r, acc ->
        Decimal.add(acc, r.amount)
      end)

      {:ok, total}
    end
  end

  # Private helpers

  defp check_refund_window(tx) do
    days_elapsed = Date.diff(Date.utc_today(), DateTime.to_date(tx.settled_at))

    if days_elapsed <= @max_refund_window_days do
      :ok
    else
      {:error, :outside_refund_window}
    end
  end

  defp check_refund_count(transaction_id) do
    count = RefundLedger.count(transaction_id)

    if count < @max_refunds_per_transaction do
      :ok
    else
      {:error, :max_refunds_reached}
    end
  end

  defp check_idempotency(key) do
    case RefundLedger.find_by_idempotency_key(key) do
      nil -> {:ok, :new}
      existing -> {:ok, {:duplicate, existing}}
    end
  end

  defp maybe_notify_customer(customer_id, amount, currency, true) do
    Logger.info("Refund notification queued for customer #{customer_id}: #{amount} #{currency}")
  end

  defp maybe_notify_customer(_, _, _, false), do: :ok

  defp generate_key do
    :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
  end
end
```
