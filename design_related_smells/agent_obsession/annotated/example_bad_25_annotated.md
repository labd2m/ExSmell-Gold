# Annotated Example — Agent Obsession

| Field | Value |
|---|---|
| **Smell name** | Agent Obsession |
| **Expected smell location** | Multiple modules: `UserRegistration`, `UserProfile`, `UserRoles`, `UserActivityLog` |
| **Affected functions** | `UserRegistration.register/2`, `UserProfile.update/3`, `UserRoles.grant/3`, `UserActivityLog.recent/2` |
| **Short explanation** | Four user-management modules each directly call `Agent` functions on a shared user store. No centralized owner of the agent exists; each module knows about and manipulates the internal state structure independently. |

```elixir
defmodule UserAgentStore do
  @moduledoc "Initializes the shared user management agent."

  def start do
    {:ok, pid} = Agent.start_link(fn ->
      %{users: %{}, activity: [], roles: %{}}
    end)
    pid
  end
end

defmodule UserRegistration do
  @moduledoc """
  Handles new user registration into the shared user agent.
  """

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because UserRegistration directly calls Agent.update/2,
  # taking on ownership of the shared user state. The `users` key structure is known
  # and written to here without any encapsulating module mediating the access.
  def register(pid, params) do
    with {:ok, email} <- validate_email(params[:email]),
         {:ok, name}  <- validate_name(params[:name]) do

      id = generate_user_id()

      user = %{
        id: id,
        name: name,
        email: email,
        hashed_password: hash_password(params[:password]),
        confirmed: false,
        created_at: DateTime.utc_now()
      }

      existing = Agent.get(pid, fn state ->
        Enum.any?(state.users, fn {_k, u} -> u.email == email end)
      end)

      if existing do
        {:error, :email_taken}
      else
        Agent.update(pid, fn state ->
          %{state | users: Map.put(state.users, id, user)}
        end)
        {:ok, user}
      end
    end
  end

  defp validate_email(nil), do: {:error, :missing_email}
  defp validate_email(e) when is_binary(e), do: {:ok, String.downcase(e)}
  defp validate_name(nil), do: {:error, :missing_name}
  defp validate_name(n) when is_binary(n), do: {:ok, n}
  defp generate_user_id, do: "usr_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  defp hash_password(pw), do: :crypto.hash(:sha256, pw) |> Base.encode16(case: :lower)
  # VALIDATION: SMELL END
end

defmodule UserProfile do
  @moduledoc """
  Updates user profile fields in the shared user agent.
  """

  @allowed_fields ~w(name bio timezone language)a

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because UserProfile directly calls Agent.update/2 and
  # Agent.get/2. This module independently owns a slice of the agent's `users` map, adding
  # another module to the set of uncoordinated agent writers.
  def update(pid, user_id, changes) do
    existing = Agent.get(pid, fn state -> Map.get(state.users, user_id) end)

    case existing do
      nil ->
        {:error, :user_not_found}

      user ->
        allowed_changes = Map.take(changes, @allowed_fields)

        Agent.update(pid, fn state ->
          updated_user = Map.merge(user, allowed_changes)
          %{state | users: Map.put(state.users, user_id, updated_user)}
        end)

        {:ok, Map.merge(user, allowed_changes)}
    end
  end

  def get(pid, user_id) do
    Agent.get(pid, fn state -> Map.get(state.users, user_id) end)
  end
  # VALIDATION: SMELL END
end

defmodule UserRoles do
  @moduledoc """
  Manages role assignments in the shared user agent.
  """

  @valid_roles ~w(admin editor viewer moderator)a

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because UserRoles is a third module directly calling
  # Agent.update/2 to write into the `roles` key of the agent. Each module assumes the
  # same internal structure independently, with no single source of truth for the schema.
  def grant(pid, user_id, role) when role in @valid_roles do
    Agent.update(pid, fn state ->
      current_roles = Map.get(state.roles, user_id, [])

      if role in current_roles do
        state
      else
        %{state | roles: Map.put(state.roles, user_id, [role | current_roles])}
      end
    end)

    :ok
  end

  def revoke(pid, user_id, role) do
    Agent.update(pid, fn state ->
      updated = Map.update(state.roles, user_id, [], fn roles -> List.delete(roles, role) end)
      %{state | roles: updated}
    end)

    :ok
  end

  def for_user(pid, user_id) do
    Agent.get(pid, fn state -> Map.get(state.roles, user_id, []) end)
  end
  # VALIDATION: SMELL END
end

defmodule UserActivityLog do
  @moduledoc """
  Records and retrieves user activity events from the shared user agent.
  """

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because UserActivityLog is a fourth module reading and
  # writing the agent directly via Agent.get/2 and Agent.update/2. Any change to the
  # `activity` list format requires updating all four modules.
  def record(pid, user_id, event_type, metadata \\ %{}) do
    entry = %{
      user_id: user_id,
      event: event_type,
      metadata: metadata,
      occurred_at: DateTime.utc_now()
    }

    Agent.update(pid, fn state ->
      %{state | activity: [entry | state.activity]}
    end)

    :ok
  end

  def recent(pid, user_id, limit \\ 20) do
    Agent.get(pid, fn state ->
      state.activity
      |> Enum.filter(fn e -> e.user_id == user_id end)
      |> Enum.take(limit)
    end)
  end

  def all_events(pid) do
    Agent.get(pid, fn state -> state.activity end)
  end
  # VALIDATION: SMELL END
end
```
