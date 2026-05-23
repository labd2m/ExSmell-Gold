```elixir
defmodule IAM.AccessPolicy do
  @moduledoc "Defines access rules for a given role."

  defstruct [
    :id,
    :role,
    :allowed_actions,
    :resource_scope,
    :time_restricted,
    :allowed_hours_start,
    :allowed_hours_end,
    :ip_restricted,
    :allowed_ip_ranges,
    :mfa_required
  ]

  def get_for_role!(role) do
    %__MODULE__{
      id: "POL-#{role}",
      role: role,
      allowed_actions: [:read, :create, :update],
      resource_scope: :own_organisation,
      time_restricted: true,
      allowed_hours_start: ~T[08:00:00],
      allowed_hours_end: ~T[20:00:00],
      ip_restricted: false,
      allowed_ip_ranges: [],
      mfa_required: false
    }
  end

  def allows_action?(%__MODULE__{allowed_actions: actions}, action) do
    action in actions
  end

  def resource_scope(%__MODULE__{resource_scope: scope}), do: scope

  def is_time_restricted?(%__MODULE__{time_restricted: true}), do: true
  def is_time_restricted?(_), do: false

  def within_allowed_hours?(%__MODULE__{allowed_hours_start: start_t, allowed_hours_end: end_t}) do
    now = Time.utc_now()
    Time.compare(now, start_t) in [:gt, :eq] and Time.compare(now, end_t) in [:lt, :eq]
  end

  def mfa_required?(%__MODULE__{mfa_required: true}), do: true
  def mfa_required?(_), do: false

  def policy_label(%__MODULE__{role: role, resource_scope: scope}) do
    "#{role}@#{scope}"
  end
end

defmodule IAM.ResourceRequest do
  @moduledoc "Represents an incoming access request."

  defstruct [:user_id, :role, :action, :resource_id, :resource_type, :organisation_id]
end

defmodule IAM.PolicyEnforcer do
  @moduledoc """
  Enforces IAM access policies by evaluating each resource request
  against the role's defined access policy.
  """

  alias IAM.{AccessPolicy, ResourceRequest}
  require Logger

  @doc """
  Evaluates whether a `ResourceRequest` should be permitted or denied.
  Returns `{:ok, :permitted}` or `{:error, reason}`.
  """
  def enforce(%ResourceRequest{} = request) do
    result = evaluate_resource_access(request.role, request.action)

    case result do
      :permitted ->
        Logger.info("Access permitted: user=#{request.user_id} action=#{request.action} resource=#{request.resource_id}")
        {:ok, :permitted}

      {:denied, reason} ->
        Logger.warning("Access denied: user=#{request.user_id} reason=#{reason}")
        {:error, reason}
    end
  end

  defp evaluate_resource_access(role, action) do
    policy       = AccessPolicy.get_for_role!(role)
    allowed      = AccessPolicy.allows_action?(policy, action)
    scope        = AccessPolicy.resource_scope(policy)
    time_limited = AccessPolicy.is_time_restricted?(policy)
    in_hours     = AccessPolicy.within_allowed_hours?(policy)

    cond do
      not allowed ->
        {:denied, :action_not_permitted}

      time_limited and not in_hours ->
        {:denied, :outside_allowed_hours}

      scope == :own_organisation and action == :delete ->
        {:denied, :delete_restricted_to_global_scope}

      true ->
        :permitted
    end
  end
end
```
