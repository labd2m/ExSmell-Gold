# Annotated Example — Long Function

## Metadata

- **Smell name:** Long Function
- **Expected smell location:** `Payments.RefundProcessor.process/3`
- **Affected function(s):** `process/3`
- **Short explanation:** The `process/3` function performs order and transaction lookup, refund eligibility window checking, partial vs. full refund logic, gateway refund dispatch, ledger entry recording, order status transition, stock reservation release, and customer notification all within a single body. The accumulated length and the number of distinct concerns clearly mark this as a Long Function.

---

```elixir
defmodule Payments.RefundProcessor do
  @moduledoc """
  Handles full and partial refunds for paid orders, coordinating with the
  payment gateway, ledger, and inventory systems.
  """

  alias Payments.{Transaction, Refund, LedgerEntry, Repo}
  alias Orders.Order
  alias Inventory.StockManager
  alias Notifications.Dispatcher
  alias Integrations.StripeGateway
  require Logger

  @refund_window_days 30
  @partial_refund_min_cents 100

  # VALIDATION: SMELL START - Long Function
  # VALIDATION: This is a smell because `process/3` combines order retrieval,
  # VALIDATION: transaction lookup, refund-window enforcement, partial/full logic,
  # VALIDATION: gateway call, ledger recording, order status update, stock release,
  # VALIDATION: and customer notification all in one excessively long function.
  def process(order_id, amount_cents, reason \\ :customer_request) do
    Logger.info("Processing refund for order=#{order_id} amount=#{amount_cents} reason=#{reason}")

    with %Order{} = order <- Repo.get(Order, order_id) |> Repo.preload(:items),
         %Transaction{} = txn <- Repo.get_by(Transaction, order_id: order_id, status: :captured) do

      # --- Check refund eligibility window ---
      days_since_charge = DateTime.diff(DateTime.utc_now(), txn.charged_at, :second) |> div(86_400)

      if days_since_charge > @refund_window_days do
        Logger.warning("Refund window expired for order #{order_id} (#{days_since_charge} days)")
        {:error, :refund_window_expired}
      else
        # --- Determine refund type and validate amount ---
        already_refunded =
          Refund
          |> Refund.for_transaction(txn.id)
          |> Repo.aggregate(:sum, :amount_cents) || 0

        max_refundable = txn.amount_cents - already_refunded

        cond do
          amount_cents < @partial_refund_min_cents ->
            {:error, :amount_below_minimum}

          amount_cents > max_refundable ->
            {:error, {:exceeds_refundable_amount, max_refundable}}

          true ->
            is_full_refund = amount_cents == max_refundable

            # --- Call gateway ---
            gateway_opts = %{
              charge_id: txn.gateway_charge_id,
              amount: amount_cents,
              reason: reason
            }

            case StripeGateway.refund(gateway_opts) do
              {:ok, %{refund_id: gw_refund_id}} ->
                # --- Record refund ---
                {:ok, refund} =
                  Repo.insert(Refund.changeset(%Refund{}, %{
                    transaction_id: txn.id,
                    order_id: order_id,
                    gateway_refund_id: gw_refund_id,
                    amount_cents: amount_cents,
                    reason: reason,
                    full_refund: is_full_refund,
                    refunded_at: DateTime.utc_now()
                  }))

                # --- Ledger entry ---
                Repo.insert!(%LedgerEntry{
                  reference_id: refund.id,
                  reference_type: "refund",
                  amount_cents: -amount_cents,
                  currency: txn.currency,
                  description: "Refund for order #{order_id}",
                  posted_at: DateTime.utc_now()
                })

                # --- Update order status ---
                new_status = if is_full_refund, do: :refunded, else: :partially_refunded

                order
                |> Order.changeset(%{status: new_status})
                |> Repo.update!()

                # --- Release stock reservations on full refund ---
                if is_full_refund do
                  Enum.each(order.items, fn item ->
                    StockManager.release_reservation(item.sku, item.quantity)
                  end)
                end

                # --- Notify customer ---
                Dispatcher.dispatch(order.user_id, %{
                  type: "refund_processed",
                  payload: %{
                    order_id: order_id,
                    amount_cents: amount_cents,
                    currency: txn.currency,
                    full_refund: is_full_refund
                  }
                })

                Logger.info("Refund #{refund.id} processed for order #{order_id}, full=#{is_full_refund}")
                {:ok, refund}

              {:error, %{code: code, message: msg}} ->
                Logger.error("Gateway refund failed for order #{order_id}: #{code} – #{msg}")
                {:error, {:gateway_error, code}}
            end
        end
      end
    else
      nil -> {:error, :order_or_transaction_not_found}
      err -> err
    end
  end
  # VALIDATION: SMELL END
end
```
