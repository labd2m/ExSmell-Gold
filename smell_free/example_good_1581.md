```elixir
defmodule Billing.Subscriptions do
  @moduledoc """
  Context for managing customer subscription lifecycles.

  Handles plan assignment, upgrades, downgrades, and cancellations.
  All state transitions are validated against the current subscription status
  before any database write is attempted.
  """

  import Ecto.Query

  alias Billing.Repo
  alias Billing.Subscriptions.{Subscription, Plan, ProratedAdjustment}

  @type result(t) :: {:ok, t} | {:error, Ecto.Changeset.t() | String.t()}

  @doc """
  Creates a new subscription for a customer on the given plan.

  Returns an error if the customer already holds an active subscription.
  """
  @spec create(String.t(), String.t()) :: result(Subscription.t())
  def create(customer_id, plan_id) when is_binary(customer_id) and is_binary(plan_id) do
    with :ok <- assert_no_active_subscription(customer_id),
         {:ok, plan} <- fetch_plan(plan_id),
         {:ok, sub} <- insert_subscription(customer_id, plan) do
      {:ok, sub}
    end
  end

  @doc """
  Upgrades or downgrades a subscription to a new plan, recording a prorated adjustment.
  """
  @spec change_plan(Subscription.t(), String.t()) :: result(Subscription.t())
  def change_plan(%Subscription{status: :active} = sub, new_plan_id) when is_binary(new_plan_id) do
    with {:ok, new_plan} <- fetch_plan(new_plan_id),
         {:ok, adjustment} <- ProratedAdjustment.calculate(sub, new_plan),
         {:ok, updated} <- apply_plan_change(sub, new_plan, adjustment) do
      {:ok, updated}
    end
  end

  def change_plan(%Subscription{status: status}, _),
    do: {:error, "cannot change plan on a #{status} subscription"}

  @doc """
  Cancels an active subscription, scheduling it to expire at the end of the billing period.
  """
  @spec cancel(Subscription.t()) :: result(Subscription.t())
  def cancel(%Subscription{status: :active} = sub) do
    sub
    |> Subscription.cancel_changeset(%{
      status: :cancelling,
      cancels_at: sub.current_period_end
    })
    |> Repo.update()
  end

  def cancel(%Subscription{status: status}),
    do: {:error, "subscription is already #{status}"}

  @doc """
  Returns all subscriptions for a customer ordered by creation date, newest first.
  """
  @spec list_for_customer(String.t()) :: [Subscription.t()]
  def list_for_customer(customer_id) when is_binary(customer_id) do
    Subscription
    |> where([s], s.customer_id == ^customer_id)
    |> order_by([s], desc: s.inserted_at)
    |> Repo.all()
  end

  # --- private helpers ---

  defp assert_no_active_subscription(customer_id) do
    exists =
      Subscription
      |> where([s], s.customer_id == ^customer_id and s.status == :active)
      |> Repo.exists?()

    if exists, do: {:error, "customer already has an active subscription"}, else: :ok
  end

  defp fetch_plan(plan_id) do
    case Repo.get(Plan, plan_id) do
      nil -> {:error, "plan not found"}
      plan -> {:ok, plan}
    end
  end

  defp insert_subscription(customer_id, plan) do
    now = DateTime.utc_now()

    %Subscription{}
    |> Subscription.create_changeset(%{
      customer_id: customer_id,
      plan_id: plan.id,
      status: :active,
      current_period_start: now,
      current_period_end: DateTime.add(now, plan.interval_days * 86_400, :second)
    })
    |> Repo.insert()
  end

  defp apply_plan_change(sub, new_plan, adjustment) do
    Repo.transaction(fn ->
      with {:ok, _adj} <- Repo.insert(adjustment),
           {:ok, updated} <-
             sub
             |> Subscription.plan_change_changeset(%{plan_id: new_plan.id})
             |> Repo.update() do
        updated
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end
end
```
