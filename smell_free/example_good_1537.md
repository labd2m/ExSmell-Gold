```elixir
defmodule Billing.SubscriptionContext do
  @moduledoc """
  Domain context for subscription lifecycle management.

  Handles plan changes, renewals, and cancellations with transactional
  integrity. All billing period boundaries are computed in UTC and
  persisted alongside the subscription record.
  """

  alias Billing.{Subscription, Plan, Repo}
  alias Ecto.Multi

  @type subscribe_result ::
          {:ok, Subscription.t()}
          | {:error, :plan_not_found}
          | {:error, :already_subscribed}
          | {:error, Ecto.Changeset.t()}

  @type change_plan_result ::
          {:ok, Subscription.t()}
          | {:error, :subscription_not_found}
          | {:error, :plan_not_found}
          | {:error, :same_plan}
          | {:error, Ecto.Changeset.t()}

  @doc """
  Creates a new subscription for an account on a given plan.

  Fails if the account already has an active subscription or the plan
  does not exist.
  """
  @spec subscribe(String.t(), String.t()) :: subscribe_result()
  def subscribe(account_id, plan_slug) when is_binary(account_id) and is_binary(plan_slug) do
    with {:ok, plan} <- fetch_plan(plan_slug),
         :ok <- assert_no_active_subscription(account_id) do
      create_subscription(account_id, plan)
    end
  end

  @doc """
  Moves an existing subscription to a different plan, effective immediately.
  """
  @spec change_plan(String.t(), String.t()) :: change_plan_result()
  def change_plan(account_id, new_plan_slug)
      when is_binary(account_id) and is_binary(new_plan_slug) do
    with {:ok, subscription} <- fetch_active_subscription(account_id),
         {:ok, new_plan} <- fetch_plan(new_plan_slug),
         :ok <- assert_different_plan(subscription, new_plan) do
      update_subscription_plan(subscription, new_plan)
    end
  end

  @doc """
  Cancels an active subscription, setting its end date to end of billing period.
  """
  @spec cancel(String.t()) ::
          {:ok, Subscription.t()} | {:error, :subscription_not_found} | {:error, Ecto.Changeset.t()}
  def cancel(account_id) when is_binary(account_id) do
    with {:ok, subscription} <- fetch_active_subscription(account_id) do
      subscription
      |> Subscription.cancel_changeset(%{
        status: :cancelled,
        cancelled_at: DateTime.utc_now(),
        ends_at: subscription.current_period_end
      })
      |> Repo.update()
    end
  end

  defp fetch_plan(slug) do
    case Repo.get_by(Plan, slug: slug, active: true) do
      nil -> {:error, :plan_not_found}
      plan -> {:ok, plan}
    end
  end

  defp fetch_active_subscription(account_id) do
    case Repo.get_by(Subscription, account_id: account_id, status: :active) do
      nil -> {:error, :subscription_not_found}
      sub -> {:ok, sub}
    end
  end

  defp assert_no_active_subscription(account_id) do
    case Repo.get_by(Subscription, account_id: account_id, status: :active) do
      nil -> :ok
      _existing -> {:error, :already_subscribed}
    end
  end

  defp assert_different_plan(%Subscription{plan_id: current_plan_id}, %Plan{id: new_plan_id}) do
    if current_plan_id == new_plan_id, do: {:error, :same_plan}, else: :ok
  end

  defp create_subscription(account_id, plan) do
    now = DateTime.utc_now()
    period_end = advance_one_billing_cycle(now, plan.billing_interval)

    %Subscription{}
    |> Subscription.changeset(%{
      account_id: account_id,
      plan_id: plan.id,
      status: :active,
      current_period_start: now,
      current_period_end: period_end
    })
    |> Repo.insert()
  end

  defp update_subscription_plan(subscription, new_plan) do
    now = DateTime.utc_now()
    period_end = advance_one_billing_cycle(now, new_plan.billing_interval)

    Multi.new()
    |> Multi.update(:subscription, Subscription.plan_change_changeset(subscription, %{
      plan_id: new_plan.id,
      current_period_start: now,
      current_period_end: period_end
    }))
    |> Repo.transaction()
    |> case do
      {:ok, %{subscription: updated}} -> {:ok, updated}
      {:error, :subscription, changeset, _} -> {:error, changeset}
    end
  end

  defp advance_one_billing_cycle(dt, :monthly) do
    %{dt | month: rem(dt.month, 12) + 1}
  end

  defp advance_one_billing_cycle(dt, :annual) do
    %{dt | year: dt.year + 1}
  end
end
```
