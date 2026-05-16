```elixir
defmodule MyApp.Subscriptions.PlanManager do
  @moduledoc """
  Manages subscription plan upgrades, downgrades, and cancellations.
  Handles proration calculations, billing cycle alignment, and
  plan entitlement changes for SaaS customer accounts.
  """

  alias MyApp.Subscriptions.Subscription
  alias MyApp.Subscriptions.Plan
  alias MyApp.Subscriptions.Proration
  alias MyApp.Billing.Invoice
  alias MyApp.Repo

  @billing_anchor :cycle_start

  defstruct [
    :account_id, :current_plan_id, :new_plan_id,
    :effective_date, :proration_amount, :status
  ]

  def current_plan(account_id) do
    case Repo.get_by(Subscription, account_id: account_id, status: :active) do
      nil -> {:error, :no_active_subscription}
      sub -> {:ok, sub}
    end
  end

  def upgrade(account_id, new_plan_id, opts \\ []) when is_list(opts) do
    confirm = Keyword.get(opts, :confirm, :preview)
    billing_anchor = Keyword.get(opts, :billing_anchor, @billing_anchor)
    immediate = Keyword.get(opts, :immediate, false)

    with {:ok, subscription} <- current_plan(account_id),
         {:ok, current_plan} <- Repo.fetch(Plan, subscription.plan_id),
         {:ok, new_plan} <- Repo.fetch(Plan, new_plan_id),
         :ok <- validate_upgrade_direction(current_plan, new_plan) do
      effective_date =
        if immediate do
          DateTime.utc_now()
        else
          next_billing_date(subscription, billing_anchor)
        end

      proration = Proration.calculate(subscription, new_plan, effective_date)

      case confirm do
        :preview ->
          %__MODULE__{
            account_id: account_id,
            current_plan_id: current_plan.id,
            new_plan_id: new_plan_id,
            effective_date: effective_date,
            proration_amount: proration.amount,
            status: :pending
          }

        :commit ->
          updated_sub = %{subscription | plan_id: new_plan_id, updated_at: DateTime.utc_now()}
          Repo.update!(updated_sub)
          {:ok, updated_sub}

        :commit_with_invoice ->
          updated_sub = %{subscription | plan_id: new_plan_id, updated_at: DateTime.utc_now()}
          Repo.update!(updated_sub)

          invoice = Invoice.generate(account_id, proration, effective_date)

          {:ok, updated_sub, invoice}
      end
    end
  end

  def downgrade(account_id, new_plan_id, opts \\ []) do
    Keyword.put(opts, :direction, :downgrade)
    upgrade(account_id, new_plan_id, opts)
  end

  def cancel(account_id, reason \\ :user_request) do
    with {:ok, subscription} <- current_plan(account_id) do
      updated = %{subscription | status: :cancelled, cancellation_reason: reason}
      Repo.update!(updated)
      {:ok, updated}
    end
  end

  defp validate_upgrade_direction(current, new_plan) do
    if new_plan.tier > current.tier do
      :ok
    else
      {:error, :not_an_upgrade}
    end
  end

  defp next_billing_date(subscription, :cycle_start) do
    Date.add(subscription.current_period_end, 1)
    |> DateTime.new!(~T[00:00:00])
  end

  defp next_billing_date(_subscription, :immediate), do: DateTime.utc_now()
end
```
