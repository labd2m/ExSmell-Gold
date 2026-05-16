```elixir
defmodule Payments.RefundProcessor do
  alias Payments.{Repo, Order, Payment, Refund, Gateway, LedgerEntry}

  require Logger

  @refund_window_days 30

  def execute_refund(order_id, amount_cents, requested_by) do
    with {:ok, order} <- fetch_completed_order(order_id),
         {:ok, payment} <- fetch_successful_payment(order),
         :ok <- validate_refund_window(payment),
         :ok <- validate_refund_amount(payment, amount_cents),
         {:ok, gateway_refund} <- Gateway.issue_refund(payment.gateway_id, amount_cents) do
      Repo.transaction(fn ->
        {:ok, refund} =
          Repo.insert(%Refund{
            order_id: order.id,
            payment_id: payment.id,
            amount_cents: amount_cents,
            gateway_refund_id: gateway_refund.id,
            requested_by: requested_by,
            status: :completed
          })

        LedgerEntry.record(:refund, refund)
        refund
      end)
    else
      {:error, :not_found} ->
        Logger.warning("Order #{order_id} not found during refund request")
        {:error, :order_not_found}

      {:error, :not_completed} ->
        Logger.warning("Refund requested on non-completed order #{order_id}")
        {:error, :order_not_eligible}

      {:error, :no_successful_payment} ->
        Logger.error("No successful payment found for order #{order_id}")
        {:error, :payment_not_found}

      {:error, :refund_window_expired} ->
        Logger.warning("Refund window expired for order #{order_id}")
        {:error, :refund_window_expired}

      {:error, :exceeds_original_amount} ->
        Logger.warning("Refund amount exceeds original payment for order #{order_id}")
        {:error, :invalid_refund_amount}

      {:error, :already_fully_refunded} ->
        Logger.info("Order #{order_id} already fully refunded")
        {:error, :already_refunded}

      {:error, :gateway_declined} ->
        Logger.error("Gateway declined refund for order #{order_id}")
        {:error, :gateway_declined}

      {:error, :gateway_unavailable} ->
        Logger.error("Gateway unavailable while processing refund for #{order_id}")
        schedule_retry(order_id, amount_cents, requested_by)
        {:error, :gateway_unavailable}
    end
  end

  defp fetch_completed_order(order_id) do
    case Repo.get(Order, order_id) do
      nil -> {:error, :not_found}
      %Order{status: :completed} = order -> {:ok, order}
      _ -> {:error, :not_completed}
    end
  end

  defp fetch_successful_payment(%Order{id: order_id}) do
    case Repo.get_by(Payment, order_id: order_id, status: :succeeded) do
      nil -> {:error, :no_successful_payment}
      payment -> {:ok, payment}
    end
  end

  defp validate_refund_window(%Payment{inserted_at: paid_at}) do
    cutoff = DateTime.add(paid_at, @refund_window_days * 86_400)

    if DateTime.compare(DateTime.utc_now(), cutoff) == :lt do
      :ok
    else
      {:error, :refund_window_expired}
    end
  end

  defp validate_refund_amount(%Payment{amount_cents: original, refunded_cents: refunded}, amount) do
    remaining = original - refunded

    cond do
      amount > original -> {:error, :exceeds_original_amount}
      amount > remaining -> {:error, :already_fully_refunded}
      true -> :ok
    end
  end

  defp schedule_retry(order_id, amount_cents, requested_by) do
    %{order_id: order_id, amount_cents: amount_cents, requested_by: requested_by}
    |> Payments.RefundRetryWorker.new(schedule_in: 900)
    |> Oban.insert()
  end
end
```
