```elixir
defmodule Subscriptions.UsageEvent do
  @enforce_keys [:id, :tenant_id, :subscription_id, :metric, :quantity, :recorded_at]
  defstruct [
    :id,
    :tenant_id,
    :subscription_id,
    :metric,
    :quantity,
    :unit,
    :recorded_at,
    :idempotency_key,
    :metadata
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          tenant_id: String.t(),
          subscription_id: String.t(),
          metric: String.t(),
          quantity: float(),
          unit: String.t(),
          recorded_at: DateTime.t(),
          idempotency_key: String.t(),
          metadata: map()
        }
end

defmodule Subscriptions.Subscription do
  @enforce_keys [:id, :tenant_id, :plan_id, :status, :current_period_start, :current_period_end]
  defstruct [
    :id,
    :tenant_id,
    :plan_id,
    :status,
    :current_period_start,
    :current_period_end,
    :billing_anchor_day,
    :metered_features,
    :add_ons,
    :trial_ends_at,
    :payment_method_id
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          tenant_id: String.t(),
          plan_id: String.t(),
          status: :active | :trialing | :past_due | :cancelled | :unpaid,
          current_period_start: Date.t(),
          current_period_end: Date.t(),
          billing_anchor_day: 1..28,
          metered_features: [map()],
          add_ons: [map()],
          trial_ends_at: Date.t() | nil,
          payment_method_id: String.t() | nil
        }
end

defmodule Subscriptions.UsageRecord do
  @enforce_keys [:subscription, :events]
  defstruct [:subscription, :events, :computed_charges, :period_totals]

  @type t :: %__MODULE__{
          subscription: Subscriptions.Subscription.t(),
          events: [Subscriptions.UsageEvent.t()],
          computed_charges: [map()],
          period_totals: %{String.t() => float()}
        }
end

defmodule Subscriptions.UsageRepository do
  @moduledoc "Loads usage data for the current billing period."

  @spec load_period_usage(Date.t(), Date.t()) :: [Subscriptions.UsageRecord.t()]
  def load_period_usage(%Date{} = period_start, %Date{} = period_end) do
    today = Date.utc_today()
    now = DateTime.utc_now()
    metrics = ["api_calls", "storage_gb", "compute_minutes", "emails_sent", "active_users"]

    Enum.map(1..10_000, fn sub_n ->
      sub = %Subscriptions.Subscription{
        id: "sub_#{sub_n}",
        tenant_id: "tenant_#{rem(sub_n, 2000) + 1}",
        plan_id: Enum.random(["starter", "growth", "enterprise"]),
        status: Enum.random([:active, :active, :trialing, :past_due]),
        current_period_start: period_start,
        current_period_end: period_end,
        billing_anchor_day: rem(sub_n, 28) + 1,
        payment_method_id: "pm_#{sub_n}",
        trial_ends_at: if(rem(sub_n, 20) == 0, do: Date.add(today, 7)),
        metered_features:
          Enum.map(metrics, fn m ->
            %{
              metric: m,
              unit_price: Float.round(:rand.uniform() * 0.10, 4),
              included_quantity: :rand.uniform(1000),
              cap: :rand.uniform(100_000)
            }
          end),
        add_ons:
          Enum.map(1..3, fn a ->
            %{id: "addon_#{a}", name: "Add-on #{a}", price: Float.round(:rand.uniform() * 50, 2)}
          end)
      }

      events =
        Enum.flat_map(metrics, fn metric ->
          Enum.map(1..40, fn e ->
            %Subscriptions.UsageEvent{
              id: "ue_#{sub_n}_#{metric}_#{e}",
              tenant_id: sub.tenant_id,
              subscription_id: sub.id,
              metric: metric,
              quantity: Float.round(:rand.uniform() * 1000, 3),
              unit: "unit",
              recorded_at: DateTime.add(now, -:rand.uniform(30) * 86_400, :second),
              idempotency_key: "idem_#{sub_n}_#{metric}_#{e}",
              metadata: %{
                source: "sdk",
                region: Enum.random(["us-east-1", "eu-west-1"]),
                ip: "10.#{rem(sub_n, 255)}.#{rem(e, 255)}.1",
                tags: ["production", "v2"]
              }
            }
          end)
        end)

      totals = Map.new(metrics, fn m ->
        total = events |> Enum.filter(&(&1.metric == m)) |> Enum.reduce(0.0, &(&1.quantity + &2))
        {m, total}
      end)

      charges = Enum.map(sub.metered_features, fn feature ->
        total = Map.get(totals, feature.metric, 0.0)
        billable = max(0.0, total - feature.included_quantity)
        %{metric: feature.metric, billable_quantity: billable,
          charge: Float.round(billable * feature.unit_price, 2)}
      end)

      %Subscriptions.UsageRecord{
        subscription: sub,
        events: events,
        period_totals: totals,
        computed_charges: charges
      }
    end)
  end
end

defmodule Subscriptions.BillingEngine do
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, [], opts)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_info({:process_usage, period, records}, _state) do
    {:noreply, {period, length(records)}}
  end
end

defmodule Subscriptions.UsageSync do
  @moduledoc """
  Periodically collects metered usage for all subscriptions and forwards
  the data to the billing engine for invoice generation.
  """

  require Logger

  @spec sync_to_billing_engine(pid()) :: :ok
  def sync_to_billing_engine(billing_pid) do
    today = Date.utc_today()
    period_start = Date.beginning_of_month(today)
    period_end = today

    Logger.info(
      "Loading usage for period #{period_start} – #{period_end}..."
    )

    records = Subscriptions.UsageRepository.load_period_usage(period_start, period_end)

    total_events = Enum.reduce(records, 0, fn r, acc -> acc + length(r.events) end)

    Logger.info(
      "Loaded #{length(records)} subscription records (#{total_events} events). " <>
        "Sending to billing engine..."
    )

    send(billing_pid, {:process_usage, {period_start, period_end}, records})

    Logger.info("Usage data dispatched to billing engine.")
    :ok
  end
end
```
