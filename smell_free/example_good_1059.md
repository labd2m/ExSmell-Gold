**File:** `example_good_1059.md`

```elixir
defmodule Billing.Subscriptions do
  @moduledoc """
  Context for managing customer subscriptions, including plan transitions,
  cancellations, and renewal scheduling. All database operations are
  transactional and return tagged result tuples.
  """

  import Ecto.Query, warn: false

  alias Billing.Repo
  alias Billing.Subscriptions.{Subscription, Plan, RenewalJob}

  @type create_params :: %{
          customer_id: Ecto.UUID.t(),
          plan_id: Ecto.UUID.t(),
          trial_ends_at: DateTime.t() | nil
        }

  @spec create(create_params()) :: {:ok, Subscription.t()} | {:error, Ecto.Changeset.t()}
  def create(%{customer_id: _, plan_id: _} = params) do
    Repo.transaction(fn ->
      with {:ok, sub} <- insert_subscription(params),
           {:ok, _job} <- schedule_renewal(sub) do
        sub
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @spec upgrade(Subscription.t(), Ecto.UUID.t()) ::
          {:ok, Subscription.t()} | {:error, Ecto.Changeset.t() | atom()}
  def upgrade(%Subscription{status: :active} = sub, new_plan_id) when is_binary(new_plan_id) do
    Repo.transaction(fn ->
      with {:ok, plan} <- fetch_plan(new_plan_id),
           {:ok, updated} <- apply_plan_change(sub, plan) do
        updated
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def upgrade(%Subscription{status: status}, _plan_id) do
    {:error, {:invalid_status, status}}
  end

  @spec cancel(Subscription.t(), :immediately | :end_of_period) ::
          {:ok, Subscription.t()} | {:error, Ecto.Changeset.t()}
  def cancel(%Subscription{} = sub, :immediately) do
    sub
    |> Subscription.cancel_changeset(%{status: :cancelled, cancelled_at: DateTime.utc_now()})
    |> Repo.update()
  end

  def cancel(%Subscription{} = sub, :end_of_period) do
    sub
    |> Subscription.cancel_changeset(%{cancel_at_period_end: true})
    |> Repo.update()
  end

  @spec get_active_for_customer(Ecto.UUID.t()) :: Subscription.t() | nil
  def get_active_for_customer(customer_id) when is_binary(customer_id) do
    Subscription
    |> where([s], s.customer_id == ^customer_id and s.status == :active)
    |> preload(:plan)
    |> Repo.one()
  end

  @spec list_expiring(DateTime.t()) :: [Subscription.t()]
  def list_expiring(%DateTime{} = before_dt) do
    Subscription
    |> where([s], s.current_period_end <= ^before_dt and s.status == :active)
    |> where([s], s.cancel_at_period_end == false)
    |> preload([:plan, :customer])
    |> Repo.all()
  end

  defp insert_subscription(params) do
    %Subscription{}
    |> Subscription.create_changeset(params)
    |> Repo.insert()
  end

  defp fetch_plan(plan_id) do
    case Repo.get(Plan, plan_id) do
      nil -> {:error, :plan_not_found}
      plan -> {:ok, plan}
    end
  end

  defp apply_plan_change(sub, plan) do
    sub
    |> Subscription.upgrade_changeset(%{plan_id: plan.id, upgraded_at: DateTime.utc_now()})
    |> Repo.update()
  end

  defp schedule_renewal(%Subscription{current_period_end: period_end} = sub) do
    %{subscription_id: sub.id}
    |> RenewalJob.new(scheduled_at: period_end)
    |> Oban.insert()
  end
end
```
