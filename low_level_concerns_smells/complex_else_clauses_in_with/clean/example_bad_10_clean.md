```elixir
defmodule Subscriptions.UpgradeManager do
  alias Subscriptions.{Repo, Account, Plan, Subscription, BillingCycle, PaymentProvider}
  alias Subscriptions.Webhooks

  require Logger

  def upgrade_subscription(account_id, target_plan_id, payment_method_id) do
    with {:ok, account} <- fetch_active_account(account_id),
         {:ok, current_sub} <- fetch_current_subscription(account),
         {:ok, target_plan} <- fetch_upgradeable_plan(current_sub, target_plan_id),
         {:ok, proration} <- BillingCycle.compute_proration(current_sub, target_plan),
         {:ok, charge} <- PaymentProvider.charge(payment_method_id, proration.amount_due) do
      Repo.transaction(fn ->
        {:ok, updated_sub} =
          current_sub
          |> Subscription.changeset(%{
            plan_id: target_plan.id,
            upgraded_at: DateTime.utc_now()
          })
          |> Repo.update()

        Webhooks.broadcast(:subscription_upgraded, updated_sub)
        updated_sub
      end)
      |> case do
        {:ok, sub} ->
          Logger.info("Account #{account_id} upgraded to plan #{target_plan_id}")
          {:ok, sub}

        error ->
          error
      end
    else
      {:error, :not_found} ->
        Logger.warning("Account #{account_id} not found during upgrade")
        {:error, :account_not_found}

      {:error, :suspended} ->
        Logger.warning("Upgrade blocked: account #{account_id} is suspended")
        {:error, :account_suspended}

      {:error, :no_active_subscription} ->
        Logger.warning("Account #{account_id} has no active subscription to upgrade")
        {:error, :no_subscription}

      {:error, :plan_not_found} ->
        Logger.warning("Plan #{target_plan_id} not found")
        {:error, :invalid_plan}

      {:error, :downgrade_not_allowed} ->
        Logger.warning("Attempted downgrade for account #{account_id} via upgrade path")
        {:error, :downgrade_not_allowed}

      {:error, :same_plan} ->
        Logger.info("Account #{account_id} already on plan #{target_plan_id}")
        {:error, :already_on_plan}

      {:error, :proration_error} ->
        Logger.error("Proration calculation failed for account #{account_id}")
        {:error, :billing_error}

      {:error, :payment_declined} ->
        Logger.warning("Payment declined during upgrade for account #{account_id}")
        {:error, :payment_declined}

      {:error, :payment_method_invalid} ->
        Logger.warning("Invalid payment method #{payment_method_id} for account #{account_id}")
        {:error, :payment_method_invalid}
    end
  end

  defp fetch_active_account(account_id) do
    case Repo.get(Account, account_id) do
      nil -> {:error, :not_found}
      %Account{status: :suspended} -> {:error, :suspended}
      account -> {:ok, account}
    end
  end

  defp fetch_current_subscription(%Account{id: account_id}) do
    case Repo.get_by(Subscription, account_id: account_id, status: :active) do
      nil -> {:error, :no_active_subscription}
      sub -> {:ok, sub}
    end
  end

  defp fetch_upgradeable_plan(%Subscription{plan_id: current_plan_id}, target_plan_id) do
    case Repo.get(Plan, target_plan_id) do
      nil ->
        {:error, :plan_not_found}

      %Plan{tier: target_tier} = plan ->
        current_plan = Repo.get!(Plan, current_plan_id)

        cond do
          target_tier < current_plan.tier -> {:error, :downgrade_not_allowed}
          target_plan_id == current_plan_id -> {:error, :same_plan}
          true -> {:ok, plan}
        end
    end
  end
end
```
