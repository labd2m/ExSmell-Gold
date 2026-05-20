```elixir
defmodule AccessController do
  @moduledoc """
  Centralized access control enforcement for the API gateway.
  Handles rate limiting, RBAC resource authorization, and IP-based
  network access policies.
  """

  alias AccessController.{
    RateLimitCheck,
    AuthorizationCheck,
    NetworkPolicyCheck,
    RateLimiter,
    PermissionStore,
    NetworkPolicyStore,
    AuditLog,
    ThreatDetector
  }

  require Logger

  @doc """
  Enforce an access control policy check.

  Accepts a `%RateLimitCheck{}`, `%AuthorizationCheck{}`, or
  `%NetworkPolicyCheck{}` and returns `:ok` or `{:error, reason}`.

  ## Examples

      iex> AccessController.enforce(%RateLimitCheck{api_key: "key_123", endpoint: "/v1/orders", method: :post})
      :ok

  """
  def enforce(%RateLimitCheck{
        api_key: api_key,
        endpoint: endpoint,
        method: method,
        client_id: client_id
      }) do
    bucket_key = "#{api_key}:#{method}:#{endpoint}"

    with {:ok, limits} <- RateLimiter.get_limits(api_key, endpoint),
         {:ok, current} <- RateLimiter.increment(bucket_key, window_seconds: limits.window),
         :ok <- check_rate_within_limit(current, limits.max_requests) do
      :ok
    else
      {:error, :rate_exceeded} ->
        AuditLog.append(:rate_limit_exceeded, %{
          api_key: api_key,
          endpoint: endpoint,
          client_id: client_id,
          exceeded_at: DateTime.utc_now()
        })

        Logger.warning("Rate limit exceeded for #{api_key} on #{method} #{endpoint}")
        {:error, :rate_limit_exceeded}

      error ->
        error
    end
  end

  # enforce role-based resource authorization for an authenticated user
  def enforce(%AuthorizationCheck{
        user_id: user_id,
        resource_type: resource_type,
        resource_id: resource_id,
        action: action
      }) do
    with {:ok, roles} <- PermissionStore.get_user_roles(user_id),
         {:ok, permissions} <- PermissionStore.resolve_permissions(roles, resource_type),
         :ok <- check_permission_granted(permissions, action),
         :ok <- check_resource_ownership(user_id, resource_type, resource_id, permissions) do
      :ok
    else
      {:error, :permission_denied} ->
        AuditLog.append(:authorization_denied, %{
          user_id: user_id,
          resource_type: resource_type,
          resource_id: resource_id,
          action: action,
          denied_at: DateTime.utc_now()
        })

        Logger.warning("Authorization denied: user=#{user_id} action=#{action} on #{resource_type}/#{resource_id}")
        {:error, :forbidden}

      error ->
        error
    end
  end

  # enforce network policy — IP allowlist/blocklist check
  def enforce(%NetworkPolicyCheck{
        ip_address: ip,
        policy_group: policy_group,
        request_path: path
      }) do
    with {:ok, policy} <- NetworkPolicyStore.fetch_policy(policy_group),
         :ok <- check_ip_not_blocked(ip, policy.blocklist),
         :ok <- check_ip_allowed(ip, policy.allowlist),
         :ok <- ThreatDetector.screen_ip(ip) do
      :ok
    else
      {:error, :ip_blocked} ->
        AuditLog.append(:network_policy_blocked, %{
          ip: ip,
          policy_group: policy_group,
          path: path,
          blocked_at: DateTime.utc_now()
        })

        Logger.warning("Network policy blocked IP #{ip} for path #{path}")
        {:error, :ip_blocked}

      {:error, :threat_detected} ->
        Logger.error("Threat detected from IP #{ip}")
        {:error, :ip_blocked}

      error ->
        error
    end
  end

  defp check_rate_within_limit(current, max) when current <= max, do: :ok
  defp check_rate_within_limit(_, _), do: {:error, :rate_exceeded}

  defp check_permission_granted(permissions, action) do
    if action in permissions.allowed_actions do
      :ok
    else
      {:error, :permission_denied}
    end
  end

  defp check_resource_ownership(user_id, resource_type, resource_id, permissions) do
    if permissions.scope == :own do
      case PermissionStore.is_owner?(user_id, resource_type, resource_id) do
        true -> :ok
        false -> {:error, :permission_denied}
      end
    else
      :ok
    end
  end

  defp check_ip_not_blocked(ip, blocklist) do
    if ip in blocklist, do: {:error, :ip_blocked}, else: :ok
  end

  defp check_ip_allowed(_ip, []), do: :ok
  defp check_ip_allowed(ip, allowlist) do
    if ip in allowlist, do: :ok, else: {:error, :ip_blocked}
  end
end
```
