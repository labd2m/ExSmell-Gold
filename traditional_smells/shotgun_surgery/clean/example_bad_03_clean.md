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

  def get_permissions(:viewer), do: @viewer_permissions
  def get_permissions(:editor), do: @editor_permissions
  def get_permissions(:admin),  do: @admin_permissions
  def get_permissions(_),       do: []

  def get_session_ttl(:viewer), do: 3_600
  def get_session_ttl(:editor), do: 7_200
  def get_session_ttl(:admin),  do: 1_800
  def get_session_ttl(_),       do: 1_800

  def audit_event_level(:viewer), do: :info
  def audit_event_level(:editor), do: :info
  def audit_event_level(:admin),  do: :notice
  def audit_event_level(_),       do: :debug

  def get_resource_quota(:viewer, :api_requests),  do: 100
  def get_resource_quota(:editor, :api_requests),  do: 1_000
  def get_resource_quota(:admin,  :api_requests),  do: 10_000
  def get_resource_quota(:viewer, :uploads),       do: 0
  def get_resource_quota(:editor, :uploads),       do: 50
  def get_resource_quota(:admin,  :uploads),       do: 500
  def get_resource_quota(_role,   _resource),      do: 0

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
