# Annotated Example — Duplicated Code

| Field | Value |
|---|---|
| **Smell name** | Duplicated Code |
| **Expected smell location** | `Subscriptions.AccessControl.can_export_data?/2` and `Subscriptions.AccessControl.can_use_api?/2` |
| **Affected functions** | `can_export_data?/2`, `can_use_api?/2` |
| **Short explanation** | Both functions reproduce the same plan-tier resolution logic (fetching the subscription, checking its status, resolving the effective plan level including overrides). A new plan tier or override mechanism must be added in both functions. |

```elixir
defmodule Subscriptions.AccessControl do
  @moduledoc """
  Evaluates feature access for users based on their active subscription plan.
  Supports plan overrides for pilot users and grandfathered accounts.
  """

  alias Subscriptions.{Subscription, Plan, Repo}

  @plan_hierarchy %{free: 0, starter: 1, professional: 2, business: 3, enterprise: 4}
  @api_access_min_plan    :professional
  @export_access_min_plan :starter

  # ---------------------------------------------------------------------------
  # Data export access
  # ---------------------------------------------------------------------------

  @doc """
  Returns `true` if the user's subscription grants data export access.
  """
  def can_export_data?(%{id: user_id} = _user, _opts \\ []) do
    # VALIDATION: SMELL START - Duplicated Code
    # VALIDATION: This is a smell because the plan-resolution logic
    # (fetch subscription, check status, apply manual override, map to
    # hierarchy level) is copy-pasted verbatim in can_use_api?/2. A new
    # status, new override rule, or new plan tier must be added in both.
    case Repo.get_active_subscription(user_id) do
      nil ->
        false

      %Subscription{status: status} when status in [:cancelled, :past_due, :suspended] ->
        false

      %Subscription{plan: plan, manual_override_plan: override} ->
        effective_plan =
          if not is_nil(override) and Map.get(@plan_hierarchy, override, -1) > Map.get(@plan_hierarchy, plan, 0),
            do: override,
            else: plan

        plan_level     = Map.get(@plan_hierarchy, effective_plan, 0)
        required_level = Map.get(@plan_hierarchy, @export_access_min_plan, 0)

        plan_level >= required_level
    end
    # VALIDATION: SMELL END
  end

  # ---------------------------------------------------------------------------
  # API access
  # ---------------------------------------------------------------------------

  @doc """
  Returns `true` if the user's subscription grants programmatic API access.
  """
  def can_use_api?(%{id: user_id} = _user, _opts \\ []) do
    # VALIDATION: SMELL START - Duplicated Code
    # VALIDATION: This is a smell because the same plan-resolution block
    # from can_export_data?/2 is duplicated here. Both must stay in sync
    # whenever the subscription model evolves.
    case Repo.get_active_subscription(user_id) do
      nil ->
        false

      %Subscription{status: status} when status in [:cancelled, :past_due, :suspended] ->
        false

      %Subscription{plan: plan, manual_override_plan: override} ->
        effective_plan =
          if not is_nil(override) and Map.get(@plan_hierarchy, override, -1) > Map.get(@plan_hierarchy, plan, 0),
            do: override,
            else: plan

        plan_level     = Map.get(@plan_hierarchy, effective_plan, 0)
        required_level = Map.get(@plan_hierarchy, @api_access_min_plan, 0)

        plan_level >= required_level
    end
    # VALIDATION: SMELL END
  end

  @doc """
  Returns `true` if the user may add additional team seats.
  """
  def can_add_seats?(%{id: user_id} = _user, requested_seats) when requested_seats > 0 do
    case Repo.get_active_subscription(user_id) do
      %Subscription{status: :active, max_seats: max, used_seats: used} ->
        used + requested_seats <= max

      _ ->
        false
    end
  end

  @doc """
  Returns the list of enabled feature flags for a user.
  """
  def enabled_features(%{id: user_id}) do
    base_features = [:core_reporting, :basic_integrations]

    case Repo.get_active_subscription(user_id) do
      %Subscription{status: :active, plan: plan} ->
        Plan.features_for(plan) ++ base_features

      _ ->
        base_features
    end
  end
end
```
