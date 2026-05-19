# Code Smell: Agent Obsession

## Metadata

- **Smell name:** Agent Obsession
- **Expected smell location:** Modules `UserRegistry`, `UserRoles`, `UserPreferences`, and `UserActivityLog`
- **Affected functions:** `UserRegistry.register/2`, `UserRoles.assign_role/3`, `UserPreferences.set_preference/3`, `UserActivityLog.record_activity/3`
- **Short explanation:** User management state shared via an Agent is accessed from four separate modules. Each module directly interacts with the agent and independently encodes knowledge of the user state structure, making the code fragile and inconsistent.

---

```elixir
defmodule UserManagement.UserRegistry do
  @moduledoc """
  Manages user registration and lookup in the system.
  """

  def start_link() do
    Agent.start_link(fn -> %{users: %{}, activity_log: []} end, name: __MODULE__)
  end

  def register(pid, user) do
    # VALIDATION: SMELL START - Agent Obsession
    # VALIDATION: This is a smell because UserRegistry directly calls Agent.update/2,
    # adding a new user to the shared state. This agent interaction responsibility
    # should not be spread across multiple modules.
    Agent.update(pid, fn state ->
      user_entry = Map.merge(user, %{
        created_at: DateTime.utc_now(),
        roles: [],
        preferences: %{}
      })
      updated_users = Map.put(state.users, user.id, user_entry)
      %{state | users: updated_users}
    end)
    # VALIDATION: SMELL END
  end

  def lookup(pid, user_id) do
    Agent.get(pid, fn state -> Map.get(state.users, user_id) end)
  end

  def all_users(pid) do
    Agent.get(pid, fn state -> Map.values(state.users) end)
  end
end

defmodule UserManagement.UserRoles do
  @moduledoc """
  Manages role assignments for registered users.
  """

  def assign_role(pid, user_id, role) do
    # VALIDATION: SMELL START - Agent Obsession
    # VALIDATION: This is a smell because UserRoles directly calls Agent.update/2 to
    # modify nested user state, independently knowing that users are stored in a map
    # keyed by user_id with a :roles list field.
    Agent.update(pid, fn state ->
      case Map.get(state.users, user_id) do
        nil ->
          state

        user ->
          updated_user = Map.update(user, :roles, [role], fn roles ->
            if role in roles, do: roles, else: [role | roles]
          end)
          %{state | users: Map.put(state.users, user_id, updated_user)}
      end
    end)
    # VALIDATION: SMELL END
  end

  def revoke_role(pid, user_id, role) do
    Agent.update(pid, fn state ->
      case Map.get(state.users, user_id) do
        nil -> state
        user ->
          updated_user = Map.update(user, :roles, [], &List.delete(&1, role))
          %{state | users: Map.put(state.users, user_id, updated_user)}
      end
    end)
  end

  def users_with_role(pid, role) do
    Agent.get(pid, fn state ->
      state.users
      |> Map.values()
      |> Enum.filter(fn user -> role in Map.get(user, :roles, []) end)
    end)
  end
end

defmodule UserManagement.UserPreferences do
  @moduledoc """
  Handles per-user preference settings.
  """

  def set_preference(pid, user_id, key, value) do
    # VALIDATION: SMELL START - Agent Obsession
    # VALIDATION: This is a smell because UserPreferences directly calls Agent.update/2
    # to mutate nested user preference state, making this the third module that
    # independently reaches into the agent to modify state.
    Agent.update(pid, fn state ->
      case Map.get(state.users, user_id) do
        nil ->
          state

        user ->
          updated_prefs = Map.put(user.preferences, key, value)
          updated_user = %{user | preferences: updated_prefs}
          %{state | users: Map.put(state.users, user_id, updated_user)}
      end
    end)
    # VALIDATION: SMELL END
  end

  def get_preference(pid, user_id, key, default \\ nil) do
    Agent.get(pid, fn state ->
      state.users
      |> Map.get(user_id, %{preferences: %{}})
      |> Map.get(:preferences, %{})
      |> Map.get(key, default)
    end)
  end
end

defmodule UserManagement.UserActivityLog do
  @moduledoc """
  Records user activity events for audit and analytics.
  """

  def record_activity(pid, user_id, action) do
    # VALIDATION: SMELL START - Agent Obsession
    # VALIDATION: This is a smell because UserActivityLog directly calls Agent.update/2
    # to append activity entries, becoming a fourth module that directly manipulates
    # the same Agent state as the other three modules.
    Agent.update(pid, fn state ->
      entry = %{user_id: user_id, action: action, timestamp: DateTime.utc_now()}
      %{state | activity_log: [entry | state.activity_log]}
    end)
    # VALIDATION: SMELL END
  end

  def activity_for_user(pid, user_id) do
    Agent.get(pid, fn state ->
      Enum.filter(state.activity_log, &(&1.user_id == user_id))
    end)
  end

  def recent_activity(pid, limit) do
    Agent.get(pid, fn state ->
      state.activity_log
      |> Enum.sort_by(& &1.timestamp, {:desc, DateTime})
      |> Enum.take(limit)
    end)
  end
end
```
