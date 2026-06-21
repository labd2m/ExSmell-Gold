# File: `example_good_81.md`

```elixir
defmodule Subscriptions.PlanManager do
  @moduledoc """
  Manages subscription plan transitions and billing cycle tracking
  for customer accounts.

  Enforces valid state transitions so that callers cannot bypass
  business rules by directly mutating the underlying record.
  """

  alias Subscriptions.{Plan, Repo, Subscription}
  alias Accounts.Customer

  import Ecto.Query, warn: false

  @type subscription_result ::
          {:ok, Subscription.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, atom()}

  @valid_transitions %{
    trial: [:active, :cancelled],
    active: [:paused, :cancelled, :past_due],
    paused: [:active, :cancelled],
    past_due: [:active, :cancelled],
    cancelled: []
  }

  @doc """
  Creates a new trial subscription for a customer on the given plan.

  Returns `{:ok, subscription}` or `{:error, reason}`.
  """
  @spec start_trial(Customer.t(), Plan.t()) :: subscription_result()
  def start_trial(%Customer{} = customer, %Plan{} = plan) do
    trial_ends_at = DateTime.add(DateTime.utc_now(), plan.trial_days, :day)

    %{
      customer_id: customer.id,
      plan_id: plan.id,
      status: :trial,
      trial_ends_at: trial_ends_at,
      current_period_start: DateTime.utc_now(),
      current_period_end: trial_ends_at
    }
    |> Subscription.create_changeset()
    |> Repo.insert()
  end

  @doc """
  Transitions a subscription to a new status.

  Only permits transitions defined in the valid transition map.
  Returns `{:ok, subscription}` or `{:error, :invalid_transition}`.
  """
  @spec transition(Subscription.t(), atom()) :: subscription_result()
  def transition(%Subscription{status: current} = subscription, new_status)
      when is_atom(new_status) do
    if new_status in Map.get(@valid_transitions, current, []) do
      apply_transition(subscription, new_status)
    else
      {:error, :invalid_transition}
    end
  end

  @doc """
  Upgrades or downgrades a subscription to a different plan.

  The change takes effect at the start of the next billing period
  unless `immediate: true` is specified.
  """
  @spec change_plan(Subscription.t(), Plan.t(), keyword()) :: subscription_result()
  def change_plan(%Subscription{status: :active} = subscription, %Plan{} = plan, opts \\ []) do
    immediate = Keyword.get(opts, :immediate, false)
    apply_plan_change(subscription, plan, immediate)
  end

  def change_plan(%Subscription{}, %Plan{}, _opts) do
    {:error, :subscription_not_active}
  end

  @doc """
  Returns all active or trial subscriptions expiring within `days` days.
  """
  @spec expiring_within(pos_integer()) :: [Subscription.t()]
  def expiring_within(days) when is_integer(days) and days > 0 do
    cutoff = DateTime.add(DateTime.utc_now(), days, :day)

    Subscription
    |> where([s], s.status in [:trial, :active])
    |> where([s], s.current_period_end <= ^cutoff)
    |> order_by([s], asc: s.current_period_end)
    |> Repo.all()
  end

  @doc """
  Renews a subscription by advancing the billing period by one cycle.
  """
  @spec renew(Subscription.t()) :: subscription_result()
  def renew(%Subscription{status: :active} = subscription) do
    next_start = subscription.current_period_end
    next_end = advance_period(next_start, subscription.billing_interval)

    subscription
    |> Subscription.renewal_changeset(%{
      current_period_start: next_start,
      current_period_end: next_end
    })
    |> Repo.update()
  end

  def renew(%Subscription{}) do
    {:error, :not_renewable}
  end

  defp apply_transition(subscription, :cancelled) do
    subscription
    |> Subscription.status_changeset(%{status: :cancelled, cancelled_at: DateTime.utc_now()})
    |> Repo.update()
  end

  defp apply_transition(subscription, new_status) do
    subscription
    |> Subscription.status_changeset(%{status: new_status})
    |> Repo.update()
  end

  defp apply_plan_change(subscription, plan, true) do
    subscription
    |> Subscription.plan_changeset(%{plan_id: plan.id})
    |> Repo.update()
  end

  defp apply_plan_change(subscription, plan, false) do
    subscription
    |> Subscription.plan_changeset(%{pending_plan_id: plan.id})
    |> Repo.update()
  end

  defp advance_period(start, :monthly), do: DateTime.add(start, 30, :day)
  defp advance_period(start, :annual), do: DateTime.add(start, 365, :day)
  defp advance_period(start, :weekly), do: DateTime.add(start, 7, :day)
end
```
