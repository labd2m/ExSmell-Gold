# Annotated Example 26

## Metadata

- **Smell name:** Accessing non-existent Map/Struct fields
- **Expected smell location:** `AccessControl.PermissionChecker.authorize/3`, lines where `policy` map keys are accessed dynamically
- **Affected function(s):** `authorize/3`
- **Short explanation:** `policy[:roles]`, `policy[:resource]`, `policy[:actions]`, and `policy[:conditions]` use dynamic bracket access. When `:roles` is absent, `nil` is passed to `Enum.member?/2`, raising `Protocol.UndefinedError`. A missing `:conditions` silently skips contextual access restrictions, granting broader permissions than intended.

---

```elixir
defmodule AccessControl.PermissionChecker do
  @moduledoc """
  Evaluates whether a principal (user or service account) is authorized
  to perform an action on a resource, given a set of access policies.
  """

  require Logger

  @valid_actions ~w(read write delete execute admin)

  @type principal :: %{
          id: String.t(),
          roles: list(String.t()),
          attributes: map()
        }

  @type auth_result :: %{
          allowed: boolean(),
          matched_policy: String.t() | nil,
          reason: String.t()
        }

  @spec authorize(principal(), String.t(), list(map())) :: auth_result()
  def authorize(principal, action, policies) when is_binary(action) do
    unless action in @valid_actions do
      Logger.warning("Unknown action requested: #{action}", principal_id: principal.id)
    end

    result =
      Enum.find_value(policies, :deny, fn policy ->
        evaluate_policy(principal, action, policy)
      end)

    case result do
      :deny ->
        %{allowed: false, matched_policy: nil, reason: "No matching allow policy"}

      {:allow, policy_id} ->
        %{allowed: true, matched_policy: policy_id, reason: "Matched policy #{policy_id}"}

      {:deny_explicit, policy_id, reason} ->
        %{allowed: false, matched_policy: policy_id, reason: reason}
    end
  end

  @spec audit_authorization(principal(), String.t(), auth_result()) :: :ok
  def audit_authorization(principal, action, result) do
    Logger.info("Authorization evaluated",
      principal_id: principal.id,
      action: action,
      allowed: result.allowed,
      matched_policy: result.matched_policy,
      reason: result.reason
    )
  end

  # ── Policy evaluation ────────────────────────────────────────────────────────

  defp evaluate_policy(principal, action, policy) do
    # VALIDATION: SMELL START - Accessing non-existent Map/Struct fields
    # VALIDATION: This is a smell because `policy[:roles]`, `policy[:resource]`,
    # `policy[:actions]`, and `policy[:conditions]` use dynamic bracket access
    # on a plain map. When `:roles` is absent, `nil` is passed to
    # `Enum.any?/2` as the enumerable, raising `Protocol.UndefinedError`.
    # When `:conditions` is absent, `nil` is returned and the
    # `conditions_met?/2` guard treats it as "no conditions required",
    # silently bypassing contextual restrictions (e.g. IP allowlists or
    # time-of-day rules) instead of treating the missing key as a policy
    # configuration error.
    roles      = policy[:roles]
    resource   = policy[:resource]
    actions    = policy[:actions]
    conditions = policy[:conditions]
    # VALIDATION: SMELL END

    policy_id = Map.get(policy, :id, "unknown")
    effect    = Map.get(policy, :effect, :allow)

    role_match    = Enum.any?(principal.roles, &Enum.member?(roles, &1))
    action_match  = action in (actions || [])
    cond_match    = conditions_met?(conditions, principal)

    cond do
      not role_match ->
        nil

      not action_match ->
        nil

      effect == :deny && role_match && action_match ->
        {:deny_explicit, policy_id, "Explicitly denied by policy #{policy_id}"}

      role_match && action_match && cond_match ->
        {:allow, policy_id}

      true ->
        nil
    end
  end

  defp conditions_met?(nil, _principal), do: true

  defp conditions_met?(conditions, principal) do
    Enum.all?(conditions, fn condition ->
      evaluate_condition(condition, principal)
    end)
  end

  defp evaluate_condition(%{type: :attribute_match, key: key, value: value}, principal) do
    Map.get(principal.attributes, key) == value
  end

  defp evaluate_condition(%{type: :ip_allowlist, ips: allowed_ips}, principal) do
    client_ip = Map.get(principal.attributes, :ip_address)
    client_ip in allowed_ips
  end

  defp evaluate_condition(%{type: :time_of_day, from: from_h, to: to_h}, _principal) do
    hour = DateTime.utc_now().hour
    hour >= from_h && hour < to_h
  end

  defp evaluate_condition(_unknown, _principal), do: false
end
```
