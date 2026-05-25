```elixir
defmodule SubscriptionManager do
  @moduledoc """
  Full subscription lifecycle: plan management, pause/resume, cancellation,
  proration, renewal billing, email notifications, MRR calculation, and
  trial management.
  """

  require Logger
  import Ecto.Query
  alias Subscriptions.Repo
  alias Subscriptions.Subscription
  alias Subscriptions.Plan
  alias Subscriptions.Invoice

  @trial_warning_days 3


  def create_subscription(user_id, plan_id) do
    plan = Repo.get!(Plan, plan_id)

    trial_ends_at =
      if plan.trial_days > 0,
        do: DateTime.add(DateTime.utc_now(), plan.trial_days * 86_400, :second),
        else: nil

    attrs = %{
      user_id: user_id,
      plan_id: plan_id,
      status: if(plan.trial_days > 0, do: :trialing, else: :active),
      current_period_start: DateTime.utc_now(),
      current_period_end: DateTime.add(DateTime.utc_now(), plan.billing_cycle_days * 86_400, :second),
      trial_ends_at: trial_ends_at
    }

    case Repo.insert(Subscription.changeset(%Subscription{}, attrs)) do
      {:ok, sub} ->
        Logger.info("Subscription #{sub.id} created for user #{user_id} on plan #{plan_id}")
        {:ok, sub}

      {:error, cs} ->
        {:error, cs}
    end
  end


  def change_plan(%Subscription{} = sub, new_plan_id) do
    old_plan = Repo.get!(Plan, sub.plan_id)
    new_plan  = Repo.get!(Plan, new_plan_id)

    proration = apply_proration(sub, new_plan)

    with {:ok, updated} <-
           sub
           |> Subscription.changeset(%{plan_id: new_plan_id})
           |> Repo.update() do
      Logger.info("Subscription #{sub.id} changed from plan #{old_plan.id} to #{new_plan.id}. Proration: #{inspect(proration)}")
      {:ok, updated, proration}
    end
  end


  def pause_subscription(%Subscription{status: :active} = sub, resume_at) do
    sub
    |> Subscription.changeset(%{status: :paused, paused_at: DateTime.utc_now(), resumes_at: resume_at})
    |> Repo.update()
  end

  def pause_subscription(%Subscription{status: status}, _), do: {:error, {:cannot_pause, status}}


  def resume_subscription(%Subscription{status: :paused} = sub) do
    plan = Repo.get!(Plan, sub.plan_id)
    new_period_end = DateTime.add(DateTime.utc_now(), plan.billing_cycle_days * 86_400, :second)

    sub
    |> Subscription.changeset(%{
         status: :active,
         paused_at: nil,
         resumes_at: nil,
         current_period_start: DateTime.utc_now(),
         current_period_end: new_period_end
       })
    |> Repo.update()
  end

  def resume_subscription(%Subscription{status: status}), do: {:error, {:not_paused, status}}


  def cancel_subscription(%Subscription{} = sub, reason) do
    with {:ok, cancelled} <-
           sub
           |> Subscription.changeset(%{
                status: :cancelled,
                cancelled_at: DateTime.utc_now(),
                cancellation_reason: reason
              })
           |> Repo.update() do
      user = Repo.get!(Subscriptions.User, sub.user_id)

      Mailer.deliver(%{
        to: user.email,
        subject: "Your subscription has been cancelled",
        text_body: "Your subscription has been cancelled. You will retain access until #{sub.current_period_end}."
      })

      {:ok, cancelled}
    end
  end


  def apply_proration(%Subscription{} = sub, new_plan) do
    old_plan = Repo.get!(Plan, sub.plan_id)
    now = DateTime.utc_now()

    remaining_seconds = DateTime.diff(sub.current_period_end, now)
    total_seconds     = DateTime.diff(sub.current_period_end, sub.current_period_start)

    remaining_fraction = if total_seconds > 0, do: remaining_seconds / total_seconds, else: 0.0

    credit  = old_plan.price_cents * remaining_fraction
    charge  = new_plan.price_cents * remaining_fraction
    net     = charge - credit

    %{credit_cents: round(credit), charge_cents: round(charge), net_cents: round(net)}
  end


  def charge_renewal(%Subscription{status: :active} = sub) do
    plan = Repo.get!(Plan, sub.plan_id)
    user = Repo.get!(Subscriptions.User, sub.user_id)

    case PaymentGateway.charge(user.gateway_customer_id, plan.price_cents) do
      {:ok, transaction_id} ->
        Repo.insert!(
          Invoice.changeset(%Invoice{}, %{
            subscription_id: sub.id,
            amount_cents: plan.price_cents,
            gateway_transaction_id: transaction_id,
            status: :paid,
            issued_at: DateTime.utc_now()
          })
        )

        new_period_end = DateTime.add(sub.current_period_end, plan.billing_cycle_days * 86_400, :second)

        sub
        |> Subscription.changeset(%{
             current_period_start: sub.current_period_end,
             current_period_end: new_period_end
           })
        |> Repo.update()

      {:error, reason} ->
        sub |> Subscription.changeset(%{status: :past_due}) |> Repo.update()
        {:error, reason}
    end
  end

  def charge_renewal(%Subscription{status: status}), do: {:error, {:not_active, status}}


  def send_renewal_notice(%Subscription{} = sub) do
    user = Repo.get!(Subscriptions.User, sub.user_id)
    plan = Repo.get!(Plan, sub.plan_id)

    Mailer.deliver(%{
      to: user.email,
      subject: "Your subscription renews soon",
      text_body:
        "Your #{plan.name} subscription will renew on #{sub.current_period_end} for $#{plan.price_cents / 100}."
    })
  end


  def calculate_mrr do
    from(s in Subscription,
      join: p in Plan, on: s.plan_id == p.id,
      where: s.status in [:active, :trialing],
      select: sum(p.price_cents)
    )
    |> Repo.one()
    |> Kernel.||(0)
    |> then(fn total_cents ->
      %{mrr_cents: total_cents, mrr_dollars: Float.round(total_cents / 100.0, 2)}
    end)
  end


  def list_expiring_trials(days_ahead \\ @trial_warning_days) do
    cutoff = DateTime.add(DateTime.utc_now(), days_ahead * 86_400, :second)

    from(s in Subscription,
      where: s.status == :trialing and s.trial_ends_at <= ^cutoff,
      order_by: [asc: s.trial_ends_at]
    )
    |> Repo.all()
  end
end
```
