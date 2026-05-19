```elixir
defmodule UserRegistry do
  @moduledoc """
  Central Agent-backed store for user accounts.
  """

  def start_link do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  def register(pid, user) do
    id = UUID.uuid4()

    entry = %{
      id: id,
      email: user.email,
      name: user.name,
      role: :guest,
      password_hash: hash(user.password),
      active: true,
      created_at: DateTime.utc_now()
    }

    Agent.update(pid, fn users -> Map.put(users, id, entry) end)
    {:ok, id}
  end

  def fetch(pid, id) do
    Agent.get(pid, fn users -> Map.fetch(users, id) end)
  end

  def deactivate(pid, id) do
    Agent.update(pid, fn users ->
      Map.update(users, id, %{}, fn u -> %{u | active: false} end)
    end)
  end

  defp hash(password), do: :crypto.hash(:sha256, password) |> Base.encode16()

  defp UUID do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end

defmodule RoleManager do
  @moduledoc """
  Manages role assignments for registered users.
  """

  @valid_roles [:guest, :member, :admin, :super_admin]

  def assign_role(pid, user_id, role) when role in @valid_roles do
    Agent.update(pid, fn users ->
      case Map.fetch(users, user_id) do
        {:ok, user} -> Map.put(users, user_id, %{user | role: role})
        :error -> users
      end
    end)

    :ok
  end

  def assign_role(_pid, _user_id, role), do: {:error, {:invalid_role, role}}

  def users_by_role(pid, role) do
    Agent.get(pid, fn users ->
      users |> Map.values() |> Enum.filter(&(&1.role == role))
    end)
  end
end

defmodule PasswordService do
  @moduledoc """
  Handles password verification and rotation for user accounts.
  """

  def update_password(pid, user_id, new_password) do
    new_hash = :crypto.hash(:sha256, new_password) |> Base.encode16()

    Agent.update(pid, fn users ->
      case Map.fetch(users, user_id) do
        {:ok, user} ->
          updated = %{user | password_hash: new_hash, password_changed_at: DateTime.utc_now()}
          Map.put(users, user_id, updated)

        :error ->
          users
      end
    end)
  end

  def verify_password(pid, user_id, candidate) do
    hash = :crypto.hash(:sha256, candidate) |> Base.encode16()

    Agent.get(pid, fn users ->
      case Map.fetch(users, user_id) do
        {:ok, %{password_hash: stored}} -> stored == hash
        :error -> false
      end
    end)
  end
end

defmodule UserReporter do
  @moduledoc """
  Generates user-related reports and statistics.
  """

  def active_summary(pid) do
    Agent.get(pid, fn users ->
      active = users |> Map.values() |> Enum.filter(& &1.active)

      by_role =
        Enum.group_by(active, & &1.role)
        |> Map.new(fn {role, list} -> {role, length(list)} end)

      %{
        total_active: length(active),
        by_role: by_role,
        newest: active |> Enum.max_by(& &1.created_at, DateTime, fn -> nil end)
      }
    end)
  end

  def inactive_users(pid) do
    Agent.get(pid, fn users ->
      users |> Map.values() |> Enum.reject(& &1.active)
    end)
  end
end
```
