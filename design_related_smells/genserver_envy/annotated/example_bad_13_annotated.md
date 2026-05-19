# Annotated Example — GenServer Envy

- **Smell name:** GenServer Envy
- **Expected smell location:** `UserRegistryAgent` — `Agent` running user management workflows
- **Affected function(s):** `register/3`, `deactivate/2`, `reset_password/3`
- **Short explanation:** User management requires external calls (email delivery, password hashing), auditing, and complex conditional logic — far beyond the shared-state purpose of an `Agent`.

```elixir
defmodule MyApp.UserRegistryAgent do
  @moduledoc """
  Central registry for user accounts. Handles registration, deactivation,
  and password reset workflows with full audit trail.
  """

  use Agent

  alias MyApp.{Mailer, PasswordHasher, TokenGenerator, AuditLog, Repo}
  alias MyApp.Accounts.{User, PasswordReset}

  @reset_token_ttl_minutes 30

  def start_link(_opts) do
    users = Repo.all(User) |> Enum.into(%{}, &{&1.id, &1})
    Agent.start_link(fn -> %{users: users, reset_tokens: %{}} end, name: __MODULE__)
  end

  def get_user(id) do
    Agent.get(__MODULE__, fn state -> Map.get(state.users, id) end)
  end

  def list_active_users do
    Agent.get(__MODULE__, fn state ->
      state.users |> Map.values() |> Enum.filter(& &1.active)
    end)
  end

  # VALIDATION: SMELL START - GenServer Envy
  # VALIDATION: This is a smell because the Agent performs full user lifecycle
  # management: hashing passwords, inserting records into a database, sending
  # welcome emails, and managing password reset token workflows. These multi-step
  # operations with side effects belong in a GenServer, not in an Agent whose
  # role is simply to provide shared access to state.

  def register(email, raw_password, role \\ :member) do
    Agent.get_and_update(__MODULE__, fn state ->
      existing = Enum.find(state.users, fn {_id, u} -> u.email == email end)

      if existing do
        {{:error, :email_taken}, state}
      else
        hashed = PasswordHasher.hash(raw_password)

        user = %User{
          id: Ecto.UUID.generate(),
          email: email,
          password_hash: hashed,
          role: role,
          active: true,
          created_at: DateTime.utc_now()
        }

        case Repo.insert(user) do
          {:ok, persisted} ->
            AuditLog.record(:user_registered, %{user_id: persisted.id, email: email})
            Mailer.deliver_welcome(email, persisted.id)
            new_state = put_in(state, [:users, persisted.id], persisted)
            {{:ok, persisted}, new_state}

          {:error, changeset} ->
            {{:error, changeset}, state}
        end
      end
    end)
  end

  def deactivate(user_id, deactivated_by) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.fetch(state.users, user_id) do
        :error ->
          {{:error, :not_found}, state}

        {:ok, %User{active: false}} ->
          {{:error, :already_inactive}, state}

        {:ok, user} ->
          updated = %{user | active: false, deactivated_at: DateTime.utc_now()}

          case Repo.update(updated) do
            {:ok, saved} ->
              AuditLog.record(:user_deactivated, %{user_id: user_id, by: deactivated_by})
              Mailer.deliver_deactivation_notice(user.email)
              new_state = put_in(state, [:users, user_id], saved)
              {{:ok, saved}, new_state}

            {:error, reason} ->
              {{:error, reason}, state}
          end
      end
    end)
  end

  def initiate_password_reset(email) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Enum.find(state.users, fn {_id, u} -> u.email == email and u.active end) do
        nil ->
          {{:error, :user_not_found}, state}

        {user_id, _user} ->
          token = TokenGenerator.generate(32)
          expires_at = DateTime.add(DateTime.utc_now(), @reset_token_ttl_minutes * 60, :second)
          reset = %PasswordReset{user_id: user_id, token: token, expires_at: expires_at}
          Mailer.deliver_reset_link(email, token)
          new_state = put_in(state, [:reset_tokens, token], reset)
          {{:ok, :sent}, new_state}
      end
    end)
  end

  def reset_password(token, new_password, confirm_password) do
    Agent.get_and_update(__MODULE__, fn state ->
      with {:ok, reset} <- Map.fetch(state.reset_tokens, token),
           :gt <- DateTime.compare(reset.expires_at, DateTime.utc_now()),
           true <- new_password == confirm_password,
           {:ok, user} <- Map.fetch(state.users, reset.user_id) do
        hashed = PasswordHasher.hash(new_password)
        updated_user = %{user | password_hash: hashed}

        case Repo.update(updated_user) do
          {:ok, saved} ->
            AuditLog.record(:password_reset, %{user_id: reset.user_id})
            new_tokens = Map.delete(state.reset_tokens, token)
            new_state = %{state | reset_tokens: new_tokens, users: Map.put(state.users, reset.user_id, saved)}
            {{:ok, :reset}, new_state}

          {:error, reason} ->
            {{:error, reason}, state}
        end
      else
        :error -> {{:error, :invalid_token}, state}
        :lt -> {{:error, :token_expired}, state}
        false -> {{:error, :passwords_do_not_match}, state}
      end
    end)
  end

  # VALIDATION: SMELL END
end
```
