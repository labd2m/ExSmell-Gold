# File: `example_good_547.md`

```elixir
defmodule Accounts.QuotaEnforcer do
  @moduledoc """
  Enforces per-account resource quotas by comparing current usage
  against plan-defined limits before allowing resource creation.

  Quota checks are advisory — they read current counts at check time.
  Callers must ensure idempotency or use database-level constraints
  for strict enforcement in high-concurrency scenarios.
  """

  import Ecto.Query, warn: false

  alias Accounts.{Plan, Quota, Repo}

  @type account_id :: Ecto.UUID.t()
  @type resource :: atom()

  @type quota_status :: %{
          resource: resource(),
          limit: non_neg_integer() | :unlimited,
          used: non_neg_integer(),
          available: non_neg_integer() | :unlimited,
          exceeded: boolean()
        }

  @type check_result :: :allowed | {:denied, :quota_exceeded, quota_status()}

  @doc """
  Checks whether `account_id` may create one more unit of `resource`.

  Returns `:allowed` when within quota, or
  `{:denied, :quota_exceeded, status}` with the current usage breakdown.
  """
  @spec check(account_id(), resource()) :: check_result()
  def check(account_id, resource)
      when is_binary(account_id) and is_atom(resource) do
    status = usage_status(account_id, resource)

    if status.exceeded do
      {:denied, :quota_exceeded, status}
    else
      :allowed
    end
  end

  @doc """
  Returns the quota status for every resource type defined on the
  account's plan.
  """
  @spec all_statuses(account_id()) :: [quota_status()]
  def all_statuses(account_id) when is_binary(account_id) do
    plan = fetch_plan(account_id)
    quotas = plan_quotas(plan)

    Enum.map(quotas, fn {resource, limit} ->
      used = current_usage(account_id, resource)
      build_status(resource, limit, used)
    end)
  end

  @doc """
  Returns the quota status for a single resource type.
  """
  @spec usage_status(account_id(), resource()) :: quota_status()
  def usage_status(account_id, resource) do
    plan = fetch_plan(account_id)
    limit = plan_limit(plan, resource)
    used = current_usage(account_id, resource)
    build_status(resource, limit, used)
  end

  @doc """
  Returns `true` when the account is within quota for all resource types.
  """
  @spec within_all_quotas?(account_id()) :: boolean()
  def within_all_quotas?(account_id) when is_binary(account_id) do
    all_statuses(account_id) |> Enum.all?(&(not &1.exceeded))
  end

  defp fetch_plan(account_id) do
    Quota
    |> where([q], q.account_id == ^account_id)
    |> join(:inner, [q], p in Plan, on: p.id == q.plan_id)
    |> select([_q, p], p)
    |> Repo.one()
  end

  defp plan_quotas(nil), do: []

  defp plan_quotas(%Plan{limits: limits}) when is_map(limits) do
    Enum.map(limits, fn {key, value} ->
      resource = if is_binary(key), do: String.to_existing_atom(key), else: key
      {resource, value}
    end)
  rescue
    ArgumentError -> []
  end

  defp plan_limit(nil, _resource), do: :unlimited

  defp plan_limit(%Plan{limits: limits}, resource) do
    string_key = Atom.to_string(resource)
    Map.get(limits, resource) || Map.get(limits, string_key) || :unlimited
  end

  defp current_usage(account_id, resource) do
    table = resource_table(resource)

    if table do
      table
      |> where([r], r.account_id == ^account_id)
      |> Repo.aggregate(:count, :id)
    else
      0
    end
  end

  defp resource_table(:projects), do: MyApp.Projects.Project
  defp resource_table(:api_keys), do: Auth.ApiKey
  defp resource_table(:team_members), do: Accounts.TeamMember
  defp resource_table(:webhooks), do: Webhooks.Endpoint
  defp resource_table(_unknown), do: nil

  defp build_status(resource, :unlimited, used) do
    %{resource: resource, limit: :unlimited, used: used, available: :unlimited, exceeded: false}
  end

  defp build_status(resource, limit, used) when is_integer(limit) do
    available = max(limit - used, 0)
    %{resource: resource, limit: limit, used: used, available: available, exceeded: used >= limit}
  end
end
```
