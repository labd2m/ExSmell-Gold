# Code Smell: Alternative Return Types

## Metadata

- **Smell name:** Alternative Return Types
- **Expected smell location:** `Subscriptions.PlanManager.upgrade/3`
- **Affected function(s):** `upgrade/3`
- **Short explanation:** The `:confirm` option changes the return from a `%PendingUpgrade{}` struct (preview), a `{:ok, %Subscription{}}` tuple (committed), or a `{:ok, %Subscription{}, invoice}` triple (with proration invoice). Callers cannot pattern-match on the result without knowing the option passed.

---

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

  # VALIDATION: SMELL START - Alternative Return Types
  # VALIDATION: This is a smell because opts[:confirm] changes the return type:
  # :preview returns a plain %PendingUpgrade{} struct (a dry-run with no DB writes),
  # :commit returns {:ok, %Subscription{}} (the saved upgraded subscription), and
  # :commit_with_invoice returns {:ok, %Subscription{}, %Invoice{}} (subscription
  # plus generated proration invoice). Each shape is structurally different,
  # and callers are forced to track which mode they used to safely consume the result.
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
  # VALIDATION: SMELL END

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
