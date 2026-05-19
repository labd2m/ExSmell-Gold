```elixir
defmodule UserStoreAgent do
  @moduledoc "Shared Agent for in-memory user records."

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{users: %{}, email_index: %{}} end, name: __MODULE__)
  end

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :permanent}
  end
end

defmodule UserRegistrar do
  @moduledoc "Handles new user registrations."

  require Logger

  @roles [:admin, :manager, :operator, :viewer]

  def register(agent, %{email: email, name: name, role: role} = attrs)
      when role in @roles do
    exists? = Agent.get(agent, fn state -> Map.has_key?(state.email_index, email) end)

    if exists? do
      {:error, :email_already_taken}
    else
      user_id = "usr_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))

      user = %{
        id: user_id,
        email: email,
        name: name,
        role: role,
        status: :active,
        preferences: Map.get(attrs, :preferences, %{}),
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      Agent.update(agent, fn state ->
        %{
          state
          | users: Map.put(state.users, user_id, user),
            email_index: Map.put(state.email_index, email, user_id)
        }
      end)

      Logger.info("Registered user #{user_id} (#{email}) as #{role}")
      {:ok, user_id}
    end
  end

  def register(_agent, %{role: role}), do: {:error, {:invalid_role, role}}
  def register(_agent, _), do: {:error, :missing_required_fields}
end
defmodule UserProfileEditor do
  @moduledoc "Applies profile updates for existing users."

  require Logger

  @updatable_fields [:name, :preferences, :notification_settings, :timezone]

  def update_profile(agent, user_id, changes) when is_map(changes) do
    filtered = Map.take(changes, @updatable_fields)

    case Agent.get(agent, fn state -> Map.get(state.users, user_id) end) do
      nil ->
        {:error, :user_not_found}

      %{status: :suspended} ->
        {:error, :user_suspended}

      user ->
        Agent.update(agent, fn state ->
          updated =
            user
            |> Map.merge(filtered)
            |> Map.put(:updated_at, DateTime.utc_now())

          %{state | users: Map.put(state.users, user_id, updated)}
        end)

        Logger.info("Updated profile for #{user_id}: #{inspect(Map.keys(filtered))}")
        :ok
    end
  end
end
defmodule UserSuspender do
  @moduledoc "Suspends and reinstates user accounts."

  require Logger

  @valid_reasons [:policy_violation, :fraud_suspicion, :inactivity, :admin_action]

  def suspend(agent, user_id, reason) when reason in @valid_reasons do
    case Agent.get(agent, fn state -> Map.get(state.users, user_id) end) do
      nil -> {:error, :user_not_found}
      %{status: :suspended} -> {:error, :already_suspended}

      user ->
        Agent.update(agent, fn state ->
          updated = %{
            user
            | status: :suspended,
              suspension_reason: reason,
              suspended_at: DateTime.utc_now(),
              updated_at: DateTime.utc_now()
          }

          %{state | users: Map.put(state.users, user_id, updated)}
        end)

        Logger.warning("Suspended user #{user_id} for #{reason}")
        :ok
    end
  end

  def reinstate(agent, user_id) do
    case Agent.get(agent, fn state -> Map.get(state.users, user_id) end) do
      nil -> {:error, :user_not_found}
      %{status: :active} -> {:error, :not_suspended}

      user ->
        Agent.update(agent, fn state ->
          updated = %{user | status: :active, suspension_reason: nil, updated_at: DateTime.utc_now()}
          %{state | users: Map.put(state.users, user_id, updated)}
        end)

        Logger.info("Reinstated user #{user_id}")
        :ok
    end
  end
end
defmodule UserDirectory do
  @moduledoc "Provides user search and listing capabilities."

  def search(agent, query) when is_binary(query) do
    lower = String.downcase(query)

    Agent.get(agent, fn state ->
      state.users
      |> Map.values()
      |> Enum.filter(fn user ->
        String.contains?(String.downcase(user.name), lower) or
          String.contains?(String.downcase(user.email), lower)
      end)
      |> Enum.sort_by(& &1.name)
    end)
  end

  def list_by_role(agent, role) do
    Agent.get(agent, fn state ->
      state.users
      |> Map.values()
      |> Enum.filter(&(&1.role == role and &1.status == :active))
    end)
  end

  def find_by_email(agent, email) do
    Agent.get(agent, fn state ->
      case Map.get(state.email_index, email) do
        nil -> nil
        user_id -> Map.get(state.users, user_id)
      end
    end)
  end
end
```
