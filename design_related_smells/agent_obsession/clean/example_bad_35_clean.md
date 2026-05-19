```elixir
defmodule UserManagement.UserRegistry do
  @moduledoc """
  Manages user registration and lookup in the system.
  """

  def start_link() do
    Agent.start_link(fn -> %{users: %{}, activity_log: []} end, name: __MODULE__)
  end

  def register(pid, user) do
    Agent.update(pid, fn state ->
      user_entry = Map.merge(user, %{
        created_at: DateTime.utc_now(),
        roles: [],
        preferences: %{}
      })
      updated_users = Map.put(state.users, user.id, user_entry)
      %{state | users: updated_users}
    end)
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
    Agent.update(pid, fn state ->
      entry = %{user_id: user_id, action: action, timestamp: DateTime.utc_now()}
      %{state | activity_log: [entry | state.activity_log]}
    end)
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
