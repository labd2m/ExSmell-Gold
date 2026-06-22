```elixir
defmodule Accounts.ImpersonationGuard do
  @moduledoc """
  Controls operator impersonation of user accounts for support purposes.
  An impersonation session is time-limited, recorded in an audit log, and
  can be revoked early. Impersonation requires the operator to hold the
  `impersonate_users` permission. The guard never impersonates admins or
  other operators to prevent privilege escalation.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias Accounts.{ImpersonationSession, User}
  alias Audit.Trail

  @type operator_id :: String.t()
  @type target_user_id :: String.t()
  @type session_id :: Ecto.UUID.t()

  @session_ttl_minutes 60
  @prohibited_roles ~w(admin operator)

  @doc """
  Creates an impersonation session for `operator_id` targeting `target_user_id`.
  Returns an error if the operator lacks the required permission, the target
  is an elevated-role user, or an active session already exists.
  """
  @spec begin_session(operator_id(), target_user_id()) ::
          {:ok, ImpersonationSession.t()}
          | {:error, :permission_denied | :target_prohibited | :session_exists | Ecto.Changeset.t()}
  def begin_session(operator_id, target_user_id)
      when is_binary(operator_id) and is_binary(target_user_id) do
    with {:ok, operator} <- fetch_and_authorise(operator_id),
         {:ok, target} <- fetch_and_check_target(target_user_id),
         :ok <- check_no_active_session(operator_id) do
      create_session(operator, target)
    end
  end

  @doc "Ends an impersonation session early by its ID."
  @spec end_session(session_id(), operator_id()) ::
          :ok | {:error, :not_found | :not_owner}
  def end_session(session_id, operator_id)
      when is_binary(session_id) and is_binary(operator_id) do
    case Repo.get(ImpersonationSession, session_id) do
      nil ->
        {:error, :not_found}

      %ImpersonationSession{operator_id: ^operator_id} = session ->
        Repo.delete!(session)
        Trail.log(%{actor_id: operator_id, action: "impersonation_ended",
                    resource_type: "ImpersonationSession", resource_id: session_id,
                    metadata: %{}, ip_address: nil})
        :ok

      %ImpersonationSession{} ->
        {:error, :not_owner}
    end
  end

  @doc "Returns the currently active impersonation session for `operator_id`, if any."
  @spec active_session(operator_id()) :: {:ok, ImpersonationSession.t()} | {:error, :none}
  def active_session(operator_id) when is_binary(operator_id) do
    now = DateTime.utc_now()

    query =
      from(s in ImpersonationSession,
        where: s.operator_id == ^operator_id and s.expires_at > ^now,
        order_by: [desc: s.inserted_at],
        limit: 1
      )

    case Repo.one(query) do
      nil -> {:error, :none}
      session -> {:ok, session}
    end
  end

  defp fetch_and_authorise(operator_id) do
    case Repo.get(User, operator_id) do
      nil -> {:error, :permission_denied}
      %User{} = op ->
        if "impersonate_users" in (op.permissions || []) do
          {:ok, op}
        else
          {:error, :permission_denied}
        end
    end
  end

  defp fetch_and_check_target(user_id) do
    case Repo.get(User, user_id) do
      nil -> {:error, :not_found}
      %User{role: role} when role in @prohibited_roles -> {:error, :target_prohibited}
      %User{} = user -> {:ok, user}
    end
  end

  defp check_no_active_session(operator_id) do
    case active_session(operator_id) do
      {:error, :none} -> :ok
      {:ok, _} -> {:error, :session_exists}
    end
  end

  defp create_session(operator, target) do
    expires_at = DateTime.add(DateTime.utc_now(), @session_ttl_minutes * 60, :second)
    attrs = %{operator_id: operator.id, target_user_id: target.id, expires_at: expires_at}

    result =
      %ImpersonationSession{}
      |> ImpersonationSession.changeset(attrs)
      |> Repo.insert()

    with {:ok, session} <- result do
      Trail.log(%{actor_id: operator.id, action: "impersonation_started",
                  resource_type: "User", resource_id: target.id,
                  metadata: %{session_id: session.id}, ip_address: nil})
      {:ok, session}
    end
  end
end
```
