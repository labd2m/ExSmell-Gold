```elixir
defmodule Subscriptions.PlanChanger do
  @moduledoc """
  Handles subscription plan upgrades and downgrades. Computes proration
  credits, schedules billing adjustments, and applies the new plan atomically
  within a single database transaction.
  """

  alias Subscriptions.{Repo, Subscription, Plan, ProratedCredit, BillingScheduler}
  alias Ecto.Multi

  @type change_result :: {:ok, Subscription.t()} | {:error, atom() | Ecto.Changeset.t()}

  @spec upgrade(Subscription.t(), Plan.t()) :: change_result()
  def upgrade(%Subscription{} = sub, %Plan{} = new_plan) do
    with :ok <- validate_upgrade(sub, new_plan) do
      credit = compute_proration(sub)
      apply_plan_change(sub, new_plan, credit, :upgraded)
    end
  end

  @spec downgrade(Subscription.t(), Plan.t()) :: change_result()
  def downgrade(%Subscription{} = sub, %Plan{} = new_plan) do
    with :ok <- validate_downgrade(sub, new_plan) do
      apply_plan_change(sub, new_plan, nil, :downgraded)
    end
  end

  @spec apply_plan_change(Subscription.t(), Plan.t(), map() | nil, atom()) :: change_result()
  defp apply_plan_change(sub, new_plan, credit, change_type) do
    Multi.new()
    |> Multi.update(:subscription, Subscription.plan_change_changeset(sub, new_plan, change_type))
    |> maybe_record_credit(credit)
    |> Multi.run(:billing, fn _repo, %{subscription: updated} ->
      BillingScheduler.reschedule(updated)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{subscription: updated}} -> {:ok, updated}
      {:error, :subscription, changeset, _} -> {:error, changeset}
      {:error, :billing, reason, _} -> {:error, reason}
      {:error, :credit, changeset, _} -> {:error, changeset}
    end
  end

  @spec maybe_record_credit(Multi.t(), map() | nil) :: Multi.t()
  defp maybe_record_credit(multi, nil), do: multi

  defp maybe_record_credit(multi, credit_params) do
    Multi.insert(multi, :credit, ProratedCredit.creation_changeset(%ProratedCredit{}, credit_params))
  end

  @spec validate_upgrade(Subscription.t(), Plan.t()) :: :ok | {:error, atom()}
  defp validate_upgrade(sub, new_plan) do
    cond do
      sub.plan_id == new_plan.id -> {:error, :same_plan}
      new_plan.price_cents <= sub.plan.price_cents -> {:error, :not_an_upgrade}
      sub.status != :active -> {:error, :subscription_not_active}
      true -> :ok
    end
  end

  @spec validate_downgrade(Subscription.t(), Plan.t()) :: :ok | {:error, atom()}
  defp validate_downgrade(sub, new_plan) do
    cond do
      sub.plan_id == new_plan.id -> {:error, :same_plan}
      new_plan.price_cents >= sub.plan.price_cents -> {:error, :not_a_downgrade}
      sub.status != :active -> {:error, :subscription_not_active}
      true -> :ok
    end
  end

  @spec compute_proration(Subscription.t()) :: map()
  defp compute_proration(sub) do
    today = Date.utc_today()
    days_remaining = Date.diff(sub.current_period_end, today)
    total_days = Date.diff(sub.current_period_end, sub.current_period_start)
    ratio = days_remaining / total_days
    credit_cents = round(sub.plan.price_cents * ratio)

    %{
      subscription_id: sub.id,
      amount_cents: credit_cents,
      reason: :plan_upgrade,
      applies_at: sub.current_period_end
    }
  end
end
```
