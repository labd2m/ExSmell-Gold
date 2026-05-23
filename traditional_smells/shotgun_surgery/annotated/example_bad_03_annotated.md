# Example Bad 03 — Annotated

## Metadata

- **Smell Name**: Shotgun Surgery
- **Expected Smell Location**: Functions `get_permissions/1`, `get_session_ttl/1`, `audit_event_level/1`, and `get_resource_quota/1` inside `Auth.AccessControl`
- **Affected Functions**: `get_permissions/1`, `get_session_ttl/1`, `audit_event_level/1`, `get_resource_quota/1`
- **Explanation**: The user role logic (`:viewer`, `:editor`, `:admin`) is scattered across four functions in the same module. Adding a new role (e.g., `:moderator`) requires four separate, independent changes — each in a different function — making this a textbook case of Shotgun Surgery.

```elixir
defmodule Auth.AccessControl do
  @moduledoc """
  Manages user permission sets, session lifetimes, resource quotas,
  and audit event severity levels for each user role in the platform.
  """

  alias Auth.{Session, AuditLog, PolicyEngine}

  @viewer_permissions  [:read_content, :view_profile, :download_reports]
  @editor_permissions  @viewer_permissions ++ [:create_content, :edit_content, :upload_media]
  @admin_permissions   @editor_permissions ++ [:manage_users, :configure_system, :view_audit_logs, :delete_content]

  def authorize(%Session{} = session, action) do
    permissions = get_permissions(session.role)

    if action in permissions do
      AuditLog.record(session.user_id, action, audit_event_level(session.role))
      :ok
    else
      AuditLog.record(session.user_id, {:denied, action}, :warning)
      {:error, :forbidden}
    end
  end

  def create_session(user, role, remote_ip) do
    ttl   = get_session_ttl(role)
    token = PolicyEngine.generate_token(user.id, role, ttl)

    %Session{
      user_id:    user.id,
      role:       role,
      token:      token,
      expires_at: DateTime.add(DateTime.utc_now(), ttl, :second),
      remote_ip:  remote_ip
    }
  end

  def check_quota(session, resource_type) do
    quota = get_resource_quota(session.role, resource_type)
    PolicyEngine.check_usage(session.user_id, resource_type, quota)
  end

  # VALIDATION: SMELL START - Shotgun Surgery [location 1 of 4]
  # VALIDATION: This is a smell because adding a new role (e.g., :moderator)
  # requires a new clause here AND in get_session_ttl/1, audit_event_level/1,
  # and get_resource_quota/2 — four scattered changes for one new role.
  def get_permissions(:viewer), do: @viewer_permissions
  def get_permissions(:editor), do: @editor_permissions
  def get_permissions(:admin),  do: @admin_permissions
  def get_permissions(_),       do: []
  # VALIDATION: SMELL END [location 1 of 4]

  # VALIDATION: SMELL START - Shotgun Surgery [location 2 of 4]
  # VALIDATION: This is a smell because a new role also requires a new TTL clause here,
  # independent of the change already needed in get_permissions/1.
  def get_session_ttl(:viewer), do: 3_600        # 1 hour
  def get_session_ttl(:editor), do: 7_200        # 2 hours
  def get_session_ttl(:admin),  do: 1_800        # 30 minutes (stricter)
  def get_session_ttl(_),       do: 1_800
  # VALIDATION: SMELL END [location 2 of 4]

  # VALIDATION: SMELL START - Shotgun Surgery [location 3 of 4]
  # VALIDATION: This is a smell because a new role also requires an audit level clause here,
  # independently from the changes in get_permissions/1 and get_session_ttl/1.
  def audit_event_level(:viewer), do: :info
  def audit_event_level(:editor), do: :info
  def audit_event_level(:admin),  do: :notice
  def audit_event_level(_),       do: :debug
  # VALIDATION: SMELL END [location 3 of 4]

  # VALIDATION: SMELL START - Shotgun Surgery [location 4 of 4]
  # VALIDATION: This is a smell because a new role also requires a new quota clause here,
  # completing the four-location change required for every new role type.
  def get_resource_quota(:viewer, :api_requests),  do: 100
  def get_resource_quota(:editor, :api_requests),  do: 1_000
  def get_resource_quota(:admin,  :api_requests),  do: 10_000
  def get_resource_quota(:viewer, :uploads),       do: 0
  def get_resource_quota(:editor, :uploads),       do: 50
  def get_resource_quota(:admin,  :uploads),       do: 500
  def get_resource_quota(_role,   _resource),      do: 0
  # VALIDATION: SMELL END [location 4 of 4]

  def validate_session(%Session{expires_at: expires_at} = session) do
    if DateTime.compare(expires_at, DateTime.utc_now()) == :gt do
      {:ok, session}
    else
      {:error, :session_expired}
    end
  end

  def revoke_session(%Session{token: token}) do
    PolicyEngine.invalidate_token(token)
  end

  def list_roles do
    [:viewer, :editor, :admin]
  end
end
```
