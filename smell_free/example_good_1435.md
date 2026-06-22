```elixir
defmodule Quotas.Enforcer do
  @moduledoc """
  Enforces per-account resource quotas before any resource creation.
  Quota limits are loaded from a policy store and checked atomically
  against current usage to prevent race-condition over-allocation.
  """

  alias Quotas.{Repo, QuotaPolicy, UsageCounter}
  import Ecto.Query

  @type account_id :: String.t()
  @type resource :: atom()

  @type quota_check ::
          :allowed
          | {:denied, %{limit: non_neg_integer(), current: non_neg_integer(), resource: resource()}}

  @spec check(account_id(), resource(), pos_integer()) :: quota_check()
  def check(account_id, resource, quantity \\ 1)
      when is_binary(account_id) and is_atom(resource) and is_integer(quantity) and quantity > 0 do
    with {:ok, policy} <- fetch_policy(account_id, resource),
         {:ok, current} <- fetch_current_usage(account_id, resource) do
      if current + quantity <= policy.limit do
        :allowed
      else
        {:denied, %{limit: policy.limit, current: current, resource: resource}}
      end
    else
      {:error, :no_policy} -> :allowed
    end
  end

  @spec check_and_increment(account_id(), resource()) :: quota_check()
  def check_and_increment(account_id, resource) when is_binary(account_id) do
    Repo.transaction(fn ->
      case check(account_id, resource) do
        :allowed ->
          UsageCounter.increment(account_id, resource)
          :allowed

        {:denied, _} = denial ->
          Repo.rollback(denial)
      end
    end)
    |> case do
      {:ok, :allowed} -> :allowed
      {:error, {:denied, _} = denial} -> denial
    end
  end

  @spec decrement(account_id(), resource()) :: :ok
  def decrement(account_id, resource) when is_binary(account_id) and is_atom(resource) do
    UsageCounter.decrement(account_id, resource)
    :ok
  end

  @spec usage_report(account_id()) :: [%{resource: resource(), current: non_neg_integer(), limit: non_neg_integer()}]
  def usage_report(account_id) when is_binary(account_id) do
    policies = fetch_all_policies(account_id)

    Enum.map(policies, fn policy ->
      {:ok, current} = fetch_current_usage(account_id, policy.resource)
      %{resource: policy.resource, current: current, limit: policy.limit}
    end)
  end

  @spec fetch_policy(account_id(), resource()) ::
          {:ok, QuotaPolicy.t()} | {:error, :no_policy}
  defp fetch_policy(account_id, resource) do
    case Repo.get_by(QuotaPolicy, account_id: account_id, resource: to_string(resource)) do
      nil -> {:error, :no_policy}
      policy -> {:ok, policy}
    end
  end

  @spec fetch_all_policies(account_id()) :: [QuotaPolicy.t()]
  defp fetch_all_policies(account_id) do
    from(p in QuotaPolicy, where: p.account_id == ^account_id) |> Repo.all()
  end

  @spec fetch_current_usage(account_id(), resource()) :: {:ok, non_neg_integer()}
  defp fetch_current_usage(account_id, resource) do
    count = UsageCounter.get(account_id, resource)
    {:ok, count}
  end
end
```
