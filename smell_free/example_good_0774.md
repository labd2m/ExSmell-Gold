```elixir
defmodule Payments.SubscriptionRenewalWorker do
  @moduledoc """
  Processes subscription renewals as scheduled GenServer tasks. Each worker
  handles a single subscription, attempts payment, and transitions the
  subscription to either active or past-due based on the outcome. Workers
  are transient and supervised under a DynamicSupervisor so failures are
  isolated to their own subscription and do not affect peers.
  """

  use GenServer

  require Logger

  alias Payments.GatewayClient
  alias Subscriptions.{BillingCycleServer, PlanRegistry}

  @type subscription_id :: String.t()
  @type renewal_outcome :: :renewed | :past_due

  @doc "Starts a renewal worker for `subscription_id`."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl GenServer
  def init(opts) do
    send(self(), :renew)
    {:ok,
     %{
       subscription_id: Keyword.fetch!(opts, :subscription_id),
       payment_method_id: Keyword.fetch!(opts, :payment_method_id),
       plan_id: Keyword.fetch!(opts, :plan_id)
     }}
  end

  @impl GenServer
  def handle_info(:renew, state) do
    outcome = attempt_renewal(state)
    log_outcome(state.subscription_id, outcome)
    apply_outcome(state.subscription_id, outcome)
    {:stop, :normal, state}
  end

  defp attempt_renewal(%{plan_id: plan_id, payment_method_id: pm_id, subscription_id: sub_id}) do
    with {:ok, plan} <- PlanRegistry.fetch(plan_id),
         {:ok, _charge} <- charge_payment(pm_id, plan, sub_id) do
      :renewed
    else
      _ -> :past_due
    end
  end

  defp charge_payment(payment_method_id, plan, subscription_id) do
    params = %{
      amount_cents: plan.price_cents,
      currency: plan.currency,
      source_token: payment_method_id,
      idempotency_key: "renewal_#{subscription_id}_#{Date.to_iso8601(Date.utc_today())}"
    }

    GatewayClient.charge(params)
  end

  defp apply_outcome(subscription_id, :renewed) do
    BillingCycleServer.mark_past_due(subscription_id)
    Logger.info("[RenewalWorker] #{subscription_id}: renewed successfully")
  end

  defp apply_outcome(subscription_id, :past_due) do
    BillingCycleServer.mark_past_due(subscription_id)
    Logger.warning("[RenewalWorker] #{subscription_id}: payment failed, marked past_due")
  end

  defp log_outcome(subscription_id, outcome) do
    :telemetry.execute(
      [:payments, :renewal, :completed],
      %{system_time: System.system_time()},
      %{subscription_id: subscription_id, outcome: outcome}
    )
  end
end
```
