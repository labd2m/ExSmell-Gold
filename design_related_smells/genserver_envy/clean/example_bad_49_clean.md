```elixir
defmodule UserAccountTask do
  @moduledoc """
  Manages the in-memory lifecycle of an authenticated user account.
  One Task is started per user upon login and kept alive until logout
  or session expiry.
  """

  require Logger

  @idle_timeout_ms :timer.minutes(30)

  @type account :: %{
          user_id: String.t(),
          email: String.t(),
          display_name: String.t(),
          role: :admin | :editor | :viewer,
          locked: boolean(),
          failed_attempts: non_neg_integer(),
          password_hash: String.t(),
          profile: map(),
          last_activity: DateTime.t()
        }

  @doc """
  Starts a Task that holds and manages state for an authenticated user.
  Returns `{:ok, pid}` on success.
  """
  def start_for_user(%{user_id: uid} = account) do
    result =
      Task.start(fn ->
        Logger.info("[UserAccountTask] Session opened for user #{uid}")

        account_loop(account)
      end)

    result
  end

  defp account_loop(account) do
    receive do
      {:update_profile, changes, from_pid} ->
        merged = Map.merge(account.profile, changes)
        updated = %{account | profile: merged, last_activity: DateTime.utc_now()}
        send(from_pid, {:update_profile_result, :ok})
        account_loop(updated)

      {:change_password, old_hash, new_hash, from_pid} ->
        if account.password_hash != old_hash do
          send(from_pid, {:change_password_result, {:error, :wrong_password}})
          account_loop(account)
        else
          updated = %{
            account
            | password_hash: new_hash,
              failed_attempts: 0,
              last_activity: DateTime.utc_now()
          }

          Logger.info("[UserAccountTask] Password changed for #{account.user_id}")
          send(from_pid, {:change_password_result, :ok})
          account_loop(updated)
        end

      {:record_failed_attempt, from_pid} ->
        new_attempts = account.failed_attempts + 1
        lock? = new_attempts >= 5

        updated = %{
          account
          | failed_attempts: new_attempts,
            locked: lock?,
            last_activity: DateTime.utc_now()
        }

        if lock? do
          Logger.warning("[UserAccountTask] Account locked for #{account.user_id}")
        end

        send(from_pid, {:failed_attempt_result, %{attempts: new_attempts, locked: lock?}})
        account_loop(updated)

      {:lock_account, reason, from_pid} ->
        updated = %{account | locked: true, last_activity: DateTime.utc_now()}
        Logger.warning("[UserAccountTask] Account #{account.user_id} locked: #{reason}")
        send(from_pid, {:lock_result, :ok})
        account_loop(updated)

      {:unlock_account, from_pid} ->
        updated = %{
          account
          | locked: false,
            failed_attempts: 0,
            last_activity: DateTime.utc_now()
        }

        Logger.info("[UserAccountTask] Account #{account.user_id} unlocked")
        send(from_pid, {:unlock_result, :ok})
        account_loop(updated)

      {:get_snapshot, from_pid} ->
        snapshot =
          Map.take(account, [
            :user_id,
            :email,
            :display_name,
            :role,
            :locked,
            :failed_attempts,
            :last_activity
          ])

        send(from_pid, {:snapshot, snapshot})
        account_loop(account)

      :logout ->
        Logger.info("[UserAccountTask] User #{account.user_id} logged out")
        :ok
    after
      @idle_timeout_ms ->
        Logger.info("[UserAccountTask] Idle timeout for #{account.user_id}")
        :timeout
    end
  end

  @doc "Sends a profile update command to the running account Task."
  def update_profile(task_pid, changes) do
    send(task_pid, {:update_profile, changes, self()})

    receive do
      {:update_profile_result, result} -> result
    after
      5_000 -> {:error, :timeout}
    end
  end

  @doc "Requests a password change via the running account Task."
  def change_password(task_pid, old_hash, new_hash) do
    send(task_pid, {:change_password, old_hash, new_hash, self()})

    receive do
      {:change_password_result, result} -> result
    after
      5_000 -> {:error, :timeout}
    end
  end

  @doc "Records a failed login attempt against the running account Task."
  def record_failed_attempt(task_pid) do
    send(task_pid, {:record_failed_attempt, self()})

    receive do
      {:failed_attempt_result, info} -> {:ok, info}
    after
      5_000 -> {:error, :timeout}
    end
  end

  @doc "Locks the account via the running Task."
  def lock_account(task_pid, reason \\ :manual) do
    send(task_pid, {:lock_account, reason, self()})

    receive do
      {:lock_result, result} -> result
    after
      5_000 -> {:error, :timeout}
    end
  end

  @doc "Fetches an account snapshot from the running Task."
  def get_snapshot(task_pid) do
    send(task_pid, {:get_snapshot, self()})

    receive do
      {:snapshot, data} -> {:ok, data}
    after
      5_000 -> {:error, :timeout}
    end
  end

  @doc "Signals the account Task to terminate."
  def logout(task_pid) do
    send(task_pid, :logout)
    :ok
  end
end
```
