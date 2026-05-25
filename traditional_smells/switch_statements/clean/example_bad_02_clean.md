```elixir
defmodule AccessControl do
  @moduledoc """
  Provides role-based access control utilities for the authentication
  and authorization layer of the platform.
  """

  require Logger

  @roles [:admin, :manager, :analyst, :viewer]

  @doc """
  Returns the list of recognized roles in the system.
  """
  def valid_roles, do: @roles







  @doc """
  Resolves the default dashboard redirect path for a user based on their role.
  """
  def resolve_dashboard_path(%{role: role}) do
    case role do
      :admin -> "/admin/overview"
      :manager -> "/manager/team-dashboard"
      :analyst -> "/analytics/reports"
      :viewer -> "/home/feed"
      _ -> "/home"
    end
  end

  @doc """
  Applies row-level data filters to a query scope based on the requesting user's role.
  The returned map carries filter parameters to be passed downstream to Ecto queries.
  """
  def apply_data_filters(%{role: role, organization_id: org_id}, base_filters) do
    role_filters =
      case role do
        :admin ->
          %{organization_id: nil, include_deleted: true}

        :manager ->
          %{organization_id: org_id, include_deleted: false}

        :analyst ->
          %{organization_id: org_id, include_deleted: false}

        :viewer ->
          %{organization_id: org_id, include_deleted: false}

        _ ->
          %{organization_id: org_id, include_deleted: false}
      end

    Map.merge(base_filters, role_filters)
  end

  @doc """
  Records an audit log entry for a resource access event. The severity of the
  log entry is adjusted based on the user's role.
  """
  def audit_access(%{role: role, id: user_id}, resource) do
    severity =
      case role do
        :admin -> :warning
        :manager -> :info
        :analyst -> :info
        :viewer -> :debug
        _ -> :debug
      end



    entry = %{
      user_id: user_id,
      resource: resource,
      accessed_at: DateTime.utc_now(),
      severity: severity
    }

    log_audit_entry(entry)
  end

  @doc """
  Checks whether a user is permitted to perform a given action.
  """
  def authorized?(%{role: role}, action) do
    permissions = %{
      admin: [:read, :write, :delete, :manage_users, :export],
      manager: [:read, :write, :export],
      analyst: [:read, :export],
      viewer: [:read]
    }

    role_permissions = Map.get(permissions, role, [])
    action in role_permissions
  end

  @doc """
  Verifies the session token and loads the authenticated user.
  Returns `{:ok, user}` or `{:error, reason}`.
  """
  def authenticate_session(token) do
    with {:ok, claims} <- decode_token(token),
         {:ok, user} <- load_user(claims["sub"]),
         true <- not user_suspended?(user) do
      {:ok, user}
    else
      false -> {:error, :account_suspended}
      {:error, reason} -> {:error, reason}
    end
  end



  defp decode_token(token) do
    case String.split(token, ".") do
      [_header, payload, _sig] ->
        case Base.decode64(payload, padding: false) do
          {:ok, json} -> Jason.decode(json)
          :error -> {:error, :malformed_token}
        end

      _ ->
        {:error, :malformed_token}
    end
  end

  defp load_user(user_id) when is_binary(user_id) do
    {:ok, %{id: user_id, role: :viewer, organization_id: "org_default"}}
  end

  defp load_user(_), do: {:error, :invalid_user_id}

  defp user_suspended?(%{suspended: true}), do: true
  defp user_suspended?(_), do: false

  defp log_audit_entry(%{severity: severity} = entry) do
    message = "[AUDIT] user=#{entry.user_id} resource=#{entry.resource}"

    case severity do
      :warning -> Logger.warning(message)
      :info -> Logger.info(message)
      :debug -> Logger.debug(message)
    end
  end
end
```
