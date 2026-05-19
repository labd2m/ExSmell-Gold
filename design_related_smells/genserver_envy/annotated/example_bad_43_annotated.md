# Annotated Bad Example 43

- **Smell name:** GenServer Envy
- **Expected smell location:** `AuthSessionTask` module — `Task`-based process
- **Affected functions:** `start_session/2`, `validate_token/2`, `refresh_token/2`, `revoke_session/1`
- **Short explanation:** A `Task` should perform a single async action and complete. Here the spawned task stays alive in a `receive` loop to serve synchronous token validation and refresh requests from other processes, acting as a stateful server — this is exactly a `GenServer`'s role.

```elixir
defmodule AuthSessionTask do
  @moduledoc """
  Manages an active authentication session for a single user.
  Tracks JWT tokens, expiry times, and refresh state.
  One task is spawned per authenticated session.
  """

  require Logger

  @token_ttl_seconds 3_600
  @refresh_window_seconds 300

  @doc """
  Starts a long-lived Task that holds session state and responds to
  token validation and refresh requests from the request pipeline.
  """
  def start_session(user_id, initial_token) do
    session = %{
      user_id: user_id,
      token: initial_token,
      issued_at: System.system_time(:second),
      refresh_count: 0,
      revoked: false
    }

    Task.start(fn -> session_loop(session) end)
  end

  # VALIDATION: SMELL START - GenServer Envy
  # VALIDATION: This is a smell because session_loop/1 keeps the Task alive
  # indefinitely, processing multiple types of incoming messages (:validate,
  # :refresh, :revoke) from different callers. A Task is designed for a single
  # async execution; persistent bidirectional communication with multiple
  # callers belongs in a GenServer.
  defp session_loop(%{revoked: true} = session) do
    Logger.info("[AuthSessionTask] Session for #{session.user_id} is revoked, stopping.")
    :ok
  end

  defp session_loop(session) do
    receive do
      {:validate, token, from_pid} ->
        now = System.system_time(:second)
        age = now - session.issued_at

        result =
          cond do
            session.revoked -> {:error, :session_revoked}
            token != session.token -> {:error, :token_mismatch}
            age > @token_ttl_seconds -> {:error, :token_expired}
            true -> {:ok, session.user_id}
          end

        send(from_pid, {:validate_result, result})
        session_loop(session)

      {:refresh, old_token, from_pid} ->
        now = System.system_time(:second)
        age = now - session.issued_at

        result =
          cond do
            session.revoked ->
              {:error, :session_revoked}

            old_token != session.token ->
              {:error, :token_mismatch}

            age < @token_ttl_seconds - @refresh_window_seconds ->
              {:error, :refresh_too_early}

            true ->
              new_token = generate_token(session.user_id)

              new_session = %{
                session
                | token: new_token,
                  issued_at: now,
                  refresh_count: session.refresh_count + 1
              }

              send(from_pid, {:refresh_result, {:ok, new_token}})
              session_loop(new_session)
              # Return early since we recurse above
              nil
          end

        if result != nil do
          send(from_pid, {:refresh_result, result})
          session_loop(session)
        end

      {:revoke, from_pid} ->
        Logger.info("[AuthSessionTask] Revoking session for #{session.user_id}")
        send(from_pid, {:revoke_result, :ok})
        session_loop(%{session | revoked: true})

      {:status, from_pid} ->
        send(from_pid, {:status_result, Map.take(session, [:user_id, :issued_at, :refresh_count, :revoked])})
        session_loop(session)
    after
      :timer.hours(2) ->
        Logger.info("[AuthSessionTask] Session idle timeout for #{session.user_id}")
        :ok
    end
  end

  # VALIDATION: SMELL END

  @doc "Validates a token by messaging the session Task."
  def validate_token(task_pid, token) do
    send(task_pid, {:validate, token, self()})

    receive do
      {:validate_result, result} -> result
    after
      5_000 -> {:error, :timeout}
    end
  end

  @doc "Requests a token refresh from the session Task."
  def refresh_token(task_pid, old_token) do
    send(task_pid, {:refresh, old_token, self()})

    receive do
      {:refresh_result, result} -> result
    after
      5_000 -> {:error, :timeout}
    end
  end

  @doc "Revokes the session managed by a given Task."
  def revoke_session(task_pid) do
    send(task_pid, {:revoke, self()})

    receive do
      {:revoke_result, result} -> result
    after
      5_000 -> {:error, :timeout}
    end
  end

  @doc "Queries session metadata from the Task."
  def get_status(task_pid) do
    send(task_pid, {:status, self()})

    receive do
      {:status_result, info} -> {:ok, info}
    after
      5_000 -> {:error, :timeout}
    end
  end

  defp generate_token(user_id) do
    :crypto.strong_rand_bytes(32)
    |> Base.url_encode64(padding: false)
    |> then(&"#{user_id}.#{&1}")
  end
end
```
