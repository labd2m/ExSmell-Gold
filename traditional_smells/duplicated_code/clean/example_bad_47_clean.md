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


  @doc """
  Returns `true` if the user's subscription grants data export access.
  """
  def can_export_data?(%{id: user_id} = _user, _opts \\ []) do
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
  end


  @doc """
  Returns `true` if the user's subscription grants programmatic API access.
  """
  def can_use_api?(%{id: user_id} = _user, _opts \\ []) do
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
