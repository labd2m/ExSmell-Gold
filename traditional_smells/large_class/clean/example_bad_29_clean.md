```elixir
defmodule SubscriptionManager do
  @moduledoc """
  Manages subscription plans, lifecycle, trials, usage, and payment recovery.
  """

  require Logger
  import Ecto.Query

  alias MyApp.Repo
  alias MyApp.Billing.{
    Plan,
    Subscription,
    SubscriptionHistory,
    Trial,
    UsageRecord,
    DunningCampaign,
    DunningStep
  }
  alias MyApp.Mailer
  alias MyApp.Accounts.Account

  @trial_days 14
  @dunning_steps [
    %{day: 1, channel: :email, template: :first_reminder},
    %{day: 3, channel: :email, template: :second_reminder},
    %{day: 7, channel: :email, template: :final_warning},
    %{day: 14, channel: :account_action, action: :suspend}
  ]


  def list_plans(opts \\ []) do
    active_only = Keyword.get(opts, :active_only, true)
    base = from p in Plan, order_by: [asc: p.sort_order]
    query = if active_only, do: from(p in base, where: p.active == true), else: base
    Repo.all(query)
  end

  def create_plan(attrs) do
    %Plan{}
    |> Plan.changeset(attrs)
    |> Repo.insert()
  end

  def update_plan(plan_id, attrs) do
    Repo.get!(Plan, plan_id)
    |> Plan.changeset(attrs)
    |> Repo.update()
  end

  def archive_plan(plan_id) do
    plan = Repo.get!(Plan, plan_id)
    subscriber_count = Repo.aggregate(from(s in Subscription, where: s.plan_id == ^plan_id and s.status == :active), :count)

    if subscriber_count > 0 do
      {:error, {:plan_has_active_subscribers, subscriber_count}}
    else
      plan |> Plan.changeset(%{active: false}) |> Repo.update()
    end
  end


  def subscribe(account_id, plan_id, opts \\ []) do
    account = Repo.get!(Account, account_id)
    plan = Repo.get!(Plan, plan_id)

    start_trial = Keyword.get(opts, :trial, true) and is_nil(previous_trial(account_id))

    {status, trial_end} =
      if start_trial do
        {:trialing, DateTime.add(DateTime.utc_now(), @trial_days * 86400, :second)}
      else
        {:active, nil}
      end

    with {:ok, sub} <-
           Repo.insert(%Subscription{
             account_id: account_id,
             plan_id: plan_id,
             status: status,
             trial_end: trial_end,
             current_period_start: DateTime.utc_now(),
             current_period_end: next_period_end(plan.billing_interval),
             started_at: DateTime.utc_now()
           }),
         {:ok, _} <- record_history(sub, nil, status, "Initial subscription") do
      if start_trial, do: activate_trial(sub)
      send_welcome(account, plan, start_trial)
      {:ok, sub}
    end
  end

  def upgrade(subscription_id, new_plan_id) do
    sub = Repo.get!(Subscription, subscription_id)
    new_plan = Repo.get!(Plan, new_plan_id)

    old_plan_id = sub.plan_id

    with {:ok, updated} <-
           sub
           |> Subscription.changeset(%{
             plan_id: new_plan_id,
             current_period_end: next_period_end(new_plan.billing_interval),
             updated_at: DateTime.utc_now()
           })
           |> Repo.update(),
         {:ok, _} <- record_history(updated, old_plan_id, :active, "Plan upgraded") do
      Logger.info("Subscription #{subscription_id} upgraded to plan #{new_plan_id}")
      {:ok, updated}
    end
  end

  def cancel(subscription_id, reason, immediate \\ false) do
    sub = Repo.get!(Subscription, subscription_id)

    attrs =
      if immediate do
        %{status: :cancelled, cancelled_at: DateTime.utc_now(), cancel_reason: reason}
      else
        %{status: :pending_cancellation, cancel_at: sub.current_period_end, cancel_reason: reason}
      end

    with {:ok, updated} <- sub |> Subscription.changeset(attrs) |> Repo.update(),
         {:ok, _} <- record_history(updated, nil, updated.status, reason) do
      {:ok, updated}
    end
  end

  defp record_history(sub, old_plan_id, new_status, note) do
    Repo.insert(%SubscriptionHistory{
      subscription_id: sub.id,
      from_plan_id: old_plan_id,
      to_plan_id: sub.plan_id,
      status: new_status,
      note: note,
      occurred_at: DateTime.utc_now()
    })
  end

  defp next_period_end(:monthly), do: DateTime.add(DateTime.utc_now(), 30 * 86400, :second)
  defp next_period_end(:annual), do: DateTime.add(DateTime.utc_now(), 365 * 86400, :second)


  defp activate_trial(%Subscription{id: sub_id, trial_end: trial_end}) do
    Repo.insert(%Trial{
      subscription_id: sub_id,
      started_at: DateTime.utc_now(),
      ends_at: trial_end,
      status: :active
    })
  end

  defp previous_trial(account_id) do
    Repo.one(
      from t in Trial,
        join: s in Subscription,
        on: t.subscription_id == s.id,
        where: s.account_id == ^account_id,
        limit: 1
    )
  end

  def expire_trials do
    now = DateTime.utc_now()

    expired =
      Repo.all(
        from t in Trial,
          where: t.status == :active and t.ends_at <= ^now
      )

    Enum.each(expired, fn trial ->
      sub = Repo.get!(Subscription, trial.subscription_id)
      sub |> Subscription.changeset(%{status: :active, trial_end: nil}) |> Repo.update()
      trial |> Trial.changeset(%{status: :expired}) |> Repo.update()
      Logger.info("Trial expired for subscription #{sub.id}")
    end)
  end


  def record_usage(subscription_id, metric, quantity, timestamp \\ DateTime.utc_now()) do
    Repo.insert(%UsageRecord{
      subscription_id: subscription_id,
      metric: metric,
      quantity: quantity,
      recorded_at: timestamp
    })
  end

  def current_period_usage(subscription_id) do
    sub = Repo.get!(Subscription, subscription_id)

    Repo.all(
      from u in UsageRecord,
        where:
          u.subscription_id == ^subscription_id and
            u.recorded_at >= ^sub.current_period_start and
            u.recorded_at <= ^sub.current_period_end,
        group_by: u.metric,
        select: %{metric: u.metric, total: sum(u.quantity)}
    )
  end

  def usage_overage(subscription_id) do
    sub = Repo.get!(Subscription, subscription_id) |> Repo.preload(:plan)
    usage = current_period_usage(subscription_id)

    Enum.flat_map(usage, fn %{metric: metric, total: total} ->
      limit = get_in(sub.plan.limits, [metric])

      if limit && total > limit do
        [%{metric: metric, used: total, limit: limit, overage: total - limit}]
      else
        []
      end
    end)
  end


  def start_dunning(subscription_id) do
    sub = Repo.get!(Subscription, subscription_id)

    {:ok, campaign} =
      Repo.insert(%DunningCampaign{
        subscription_id: subscription_id,
        started_at: DateTime.utc_now(),
        status: :active
      })

    Enum.each(@dunning_steps, fn step ->
      Repo.insert(%DunningStep{
        campaign_id: campaign.id,
        day_offset: step.day,
        channel: step.channel,
        template: step[:template],
        action: step[:action],
        scheduled_at: DateTime.add(DateTime.utc_now(), step.day * 86400, :second),
        status: :pending
      })
    end)

    Logger.info("Dunning campaign #{campaign.id} started for subscription #{subscription_id}")
    {:ok, campaign}
  end

  def process_dunning_steps do
    now = DateTime.utc_now()

    due_steps =
      Repo.all(
        from d in DunningStep,
          where: d.status == :pending and d.scheduled_at <= ^now,
          preload: [:campaign]
      )

    Enum.each(due_steps, fn step ->
      execute_dunning_step(step)
      step |> DunningStep.changeset(%{status: :executed, executed_at: now}) |> Repo.update()
    end)
  end

  defp execute_dunning_step(%DunningStep{channel: :email, template: tmpl, campaign: campaign}) do
    sub = Repo.get!(Subscription, campaign.subscription_id)
    account = Repo.get!(Account, sub.account_id)

    Mailer.send(%{
      to: account.billing_email,
      subject: dunning_subject(tmpl),
      body: dunning_body(tmpl, account)
    })
  end

  defp execute_dunning_step(%DunningStep{channel: :account_action, action: :suspend, campaign: campaign}) do
    sub = Repo.get!(Subscription, campaign.subscription_id)
    sub |> Subscription.changeset(%{status: :suspended}) |> Repo.update()
  end

  defp dunning_subject(:first_reminder), do: "Payment failed — please update your billing info"
  defp dunning_subject(:second_reminder), do: "Action required: Your payment is still overdue"
  defp dunning_subject(:final_warning), do: "Final notice: Account suspension in 7 days"

  defp dunning_body(:first_reminder, account),
    do: "Hi #{account.name}, your recent payment failed. Please update your payment method."

  defp dunning_body(:second_reminder, account),
    do: "Hi #{account.name}, we still couldn't process your payment. Please act now."

  defp dunning_body(:final_warning, account),
    do: "Hi #{account.name}, your account will be suspended in 7 days due to non-payment."

  defp send_welcome(account, plan, _is_trial = true) do
    Mailer.send(%{
      to: account.billing_email,
      subject: "Your #{@trial_days}-day free trial has started",
      body: "Welcome! Your trial of #{plan.name} is now active."
    })
  end

  defp send_welcome(account, plan, _is_trial) do
    Mailer.send(%{
      to: account.billing_email,
      subject: "Subscription to #{plan.name} confirmed",
      body: "Thank you for subscribing to #{plan.name}."
    })
  end
end
```
