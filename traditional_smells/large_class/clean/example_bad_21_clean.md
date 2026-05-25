```elixir
defmodule PaymentProcessor do
  @moduledoc """
  Handles all aspects of payment processing and financial operations.
  """

  require Logger

  alias MyApp.Repo
  alias MyApp.Payments.{Payment, Refund, Dispute, ReconciliationEntry}
  alias MyApp.Gateways.{StripeClient, PayPalClient}

  @fraud_score_threshold 70
  @max_refund_days 90
  @supported_gateways [:stripe, :paypal]


  def charge(order_id, amount, currency, method) do
    with {:ok, order} <- load_order(order_id),
         {:ok, score} <- score_fraud_risk(order, amount, method),
         :ok <- check_fraud_threshold(score),
         {:ok, gateway_resp} <- execute_charge(method.gateway, amount, currency, method.token),
         {:ok, payment} <- persist_payment(order_id, amount, currency, gateway_resp) do
      Logger.info("Payment #{payment.id} succeeded for order #{order_id}")
      {:ok, payment}
    else
      {:error, :fraud_risk_too_high} ->
        Logger.warning("Fraud risk too high for order #{order_id}")
        {:error, :fraud_risk_too_high}

      {:error, reason} ->
        Logger.error("Payment failed for order #{order_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp execute_charge(:stripe, amount, currency, token) do
    StripeClient.charge(%{amount: amount, currency: currency, source: token})
  end

  defp execute_charge(:paypal, amount, currency, token) do
    PayPalClient.capture(%{amount: amount, currency: currency, order_id: token})
  end

  defp execute_charge(gw, _, _, _), do: {:error, {:unsupported_gateway, gw}}

  defp persist_payment(order_id, amount, currency, %{id: external_id, status: status}) do
    Repo.insert(%Payment{
      order_id: order_id,
      amount: amount,
      currency: currency,
      external_id: external_id,
      status: status,
      processed_at: DateTime.utc_now()
    })
  end

  defp load_order(order_id) do
    case Repo.get(MyApp.Orders.Order, order_id) do
      nil -> {:error, :order_not_found}
      order -> {:ok, order}
    end
  end


  defp score_fraud_risk(order, amount, method) do
    score =
      0
      |> add_score_if(amount > 5000, 30)
      |> add_score_if(order.customer.account_age_days < 7, 25)
      |> add_score_if(method.gateway != order.customer.preferred_gateway, 10)
      |> add_score_if(order.shipping_country != order.customer.country, 20)

    Logger.debug("Fraud score for order #{order.id}: #{score}")
    {:ok, score}
  end

  defp check_fraud_threshold(score) when score >= @fraud_score_threshold,
    do: {:error, :fraud_risk_too_high}

  defp check_fraud_threshold(_), do: :ok

  defp add_score_if(score, true, points), do: score + points
  defp add_score_if(score, false, _), do: score


  def refund(payment_id, amount, reason) do
    payment = Repo.get!(Payment, payment_id)

    with :ok <- validate_refund_eligibility(payment, amount),
         {:ok, gateway_resp} <- issue_gateway_refund(payment, amount),
         {:ok, refund} <-
           Repo.insert(%Refund{
             payment_id: payment_id,
             amount: amount,
             reason: reason,
             external_refund_id: gateway_resp.id,
             refunded_at: DateTime.utc_now()
           }) do
      Logger.info("Refund #{refund.id} issued for payment #{payment_id}")
      {:ok, refund}
    end
  end

  defp validate_refund_eligibility(payment, amount) do
    age_days = DateTime.diff(DateTime.utc_now(), payment.processed_at, :day)

    cond do
      payment.status != :succeeded -> {:error, :payment_not_succeeded}
      age_days > @max_refund_days -> {:error, :refund_window_expired}
      amount > payment.amount -> {:error, :refund_exceeds_payment}
      true -> :ok
    end
  end

  defp issue_gateway_refund(%Payment{external_id: ext_id, gateway: :stripe}, amount) do
    StripeClient.refund(%{charge: ext_id, amount: amount})
  end

  defp issue_gateway_refund(%Payment{external_id: ext_id, gateway: :paypal}, amount) do
    PayPalClient.refund(%{capture_id: ext_id, amount: amount})
  end


  def open_dispute(payment_id, reason, evidence) do
    payment = Repo.get!(Payment, payment_id)

    Repo.insert(%Dispute{
      payment_id: payment_id,
      reason: reason,
      evidence: evidence,
      status: :open,
      opened_at: DateTime.utc_now(),
      deadline_at: DateTime.add(DateTime.utc_now(), 7 * 86400, :second)
    })
    |> case do
      {:ok, dispute} ->
        Logger.info("Dispute #{dispute.id} opened for payment #{payment.id}")
        {:ok, dispute}

      err ->
        err
    end
  end

  def resolve_dispute(dispute_id, :won) do
    dispute = Repo.get!(Dispute, dispute_id)
    dispute |> Dispute.changeset(%{status: :won, resolved_at: DateTime.utc_now()}) |> Repo.update()
  end

  def resolve_dispute(dispute_id, :lost) do
    dispute = Repo.get!(Dispute, dispute_id)

    with {:ok, updated} <-
           dispute
           |> Dispute.changeset(%{status: :lost, resolved_at: DateTime.utc_now()})
           |> Repo.update(),
         payment <- Repo.get!(Payment, dispute.payment_id),
         {:ok, _} <-
           payment
           |> Payment.changeset(%{status: :disputed_lost})
           |> Repo.update() do
      {:ok, updated}
    end
  end


  def reconcile_day(date) do
    payments =
      Repo.all(
        from p in Payment,
          where: fragment("DATE(?)", p.processed_at) == ^date and p.status == :succeeded
      )

    total = Enum.reduce(payments, Decimal.new(0), &Decimal.add(&2, &1.amount))

    Repo.insert(%ReconciliationEntry{
      date: date,
      payment_count: length(payments),
      total_amount: total,
      reconciled_at: DateTime.utc_now()
    })
    |> case do
      {:ok, entry} ->
        Logger.info("Reconciliation for #{date}: #{length(payments)} payments, total #{total}")
        {:ok, entry}

      err ->
        err
    end
  end

  def reconciliation_discrepancies(date) do
    entry = Repo.get_by!(ReconciliationEntry, date: date)

    gateway_totals =
      @supported_gateways
      |> Enum.map(fn gw ->
        {gw, fetch_gateway_total(gw, date)}
      end)

    Enum.filter(gateway_totals, fn {_gw, total} ->
      Decimal.compare(total, entry.total_amount) != :eq
    end)
  end

  defp fetch_gateway_total(:stripe, date), do: StripeClient.daily_total(date)
  defp fetch_gateway_total(:paypal, date), do: PayPalClient.daily_total(date)
end
```
