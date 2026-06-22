```elixir
defmodule Accounts.LoginAttemptTracker do
  @moduledoc """
  Tracks failed login attempts per account to support progressive lockout.
  After a configurable number of consecutive failures the account is locked
  for a growing backoff period. Successful logins reset the counter. All
  state is persisted to the database so lockouts survive application restarts.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias Accounts.LoginAttempt

  @type email :: String.t()

  @max_attempts 5
  @base_lockout_minutes 5
  @lockout_multiplier 2

  @doc "Records a failed login attempt for `email`. Returns the updated attempt record."
  @spec record_failure(email()) :: {:ok, LoginAttempt.t()} | {:error, Ecto.Changeset.t()}
  def record_failure(email) when is_binary(email) do
    Repo.transaction(fn ->
      record = get_or_build(email)
      new_count = record.failure_count + 1

      locked_until =
        if new_count >= @max_attempts do
          lockout_minutes = @base_lockout_minutes * round(:math.pow(@lockout_multiplier, new_count - @max_attempts))
          DateTime.add(DateTime.utc_now(), lockout_minutes * 60, :second)
        else
          nil
        end

      attrs = %{failure_count: new_count, locked_until: locked_until, last_failed_at: DateTime.utc_now()}

      record
      |> LoginAttempt.changeset(attrs)
      |> Repo.insert_or_update!()
    end)
  end

  @doc "Resets the failure counter on successful authentication."
  @spec record_success(email()) :: :ok
  def record_success(email) when is_binary(email) do
    Repo.delete_all(from(a in LoginAttempt, where: a.email == ^email))
    :ok
  end

  @doc """
  Returns `{:ok, :allowed}` when the account may attempt login, or
  `{:error, :locked, locked_until}` when a lockout is in effect.
  """
  @spec check(email()) :: {:ok, :allowed} | {:error, :locked, DateTime.t()}
  def check(email) when is_binary(email) do
    now = DateTime.utc_now()

    case Repo.get_by(LoginAttempt, email: email) do
      nil ->
        {:ok, :allowed}

      %LoginAttempt{locked_until: nil} ->
        {:ok, :allowed}

      %LoginAttempt{locked_until: locked_until} ->
        if DateTime.compare(now, locked_until) == :lt do
          {:error, :locked, locked_until}
        else
          {:ok, :allowed}
        end
    end
  end

  @doc "Returns the current failure count for `email`, or 0 if no record exists."
  @spec failure_count(email()) :: non_neg_integer()
  def failure_count(email) when is_binary(email) do
    case Repo.get_by(LoginAttempt, email: email) do
      nil -> 0
      %LoginAttempt{failure_count: count} -> count
    end
  end

  defp get_or_build(email) do
    Repo.get_by(LoginAttempt, email: email) || %LoginAttempt{email: email, failure_count: 0}
  end
end
```
