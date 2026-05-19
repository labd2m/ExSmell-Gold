# Annotated Example — GenServer Envy

- **Smell name:** GenServer Envy
- **Expected smell location:** `AuthSessionTask` module — `Task` acting as a long-lived session server
- **Affected function(s):** `start_session/2`, `session_loop/1`, `validate_token/2`, `revoke/1`
- **Short explanation:** A `Task` is designed for one-shot async computation. Here it runs a `receive` loop responding to session validation requests, token revocation, and refresh operations — a classic `GenServer` responsibility.

```elixir
defmodule MyApp.AuthSessionTask do
  @moduledoc """
  Manages an authenticated session for a user including token validation,
  refresh, and revocation.
  """

  alias MyApp.{TokenStore, AuditLog}
  alias MyApp.Auth.{Session, TokenPair}

  @session_ttl_s 3_600
  @refresh_window_s 300

  def start_session(user_id, token_pair) do
    # VALIDATION: SMELL START - GenServer Envy
    # VALIDATION: This is a smell because Task.start_link is used to spawn a
    # process that then enters a persistent receive loop — acting as a long-lived
    # server that handles multiple distinct message types and sends back replies.
    # This multi-message, stateful communication pattern is precisely what
    # GenServer is designed for.
    Task.start_link(fn ->
      session = %Session{
        id: Ecto.UUID.generate(),
        user_id: user_id,
        token_pair: token_pair,
        created_at: DateTime.utc_now(),
        expires_at: DateTime.add(DateTime.utc_now(), @session_ttl_s, :second),
        revoked: false
      }

      session_loop(session)
    end)
  end

  defp session_loop(%Session{revoked: true} = session) do
    receive do
      {:validate, from, _token} ->
        send(from, {:error, :session_revoked})
        session_loop(session)

      {:get_info, from} ->
        send(from, {:ok, Map.take(session, [:id, :user_id, :revoked, :expires_at])})
        session_loop(session)

      :stop ->
        :ok
    end
  end

  defp session_loop(session) do
    receive do
      {:validate, from, token} ->
        now = DateTime.utc_now()

        result =
          cond do
            DateTime.compare(session.expires_at, now) == :lt ->
              {:error, :expired}

            token != session.token_pair.access_token ->
              AuditLog.record(:invalid_token, session.user_id)
              {:error, :invalid_token}

            true ->
              remaining = DateTime.diff(session.expires_at, now, :second)
              {:ok, %{user_id: session.user_id, remaining_seconds: remaining}}
          end

        send(from, result)
        session_loop(session)

      {:refresh, from, refresh_token} ->
        now = DateTime.utc_now()
        window_start = DateTime.add(session.expires_at, -@refresh_window_s, :second)
        in_window? = DateTime.compare(now, window_start) in [:gt, :eq]

        if in_window? and refresh_token == session.token_pair.refresh_token do
          case TokenStore.rotate(session.token_pair) do
            {:ok, new_pair} ->
              new_session = %{
                session
                | token_pair: new_pair,
                  expires_at: DateTime.add(now, @session_ttl_s, :second)
              }
              send(from, {:ok, new_pair})
              session_loop(new_session)

            {:error, reason} ->
              send(from, {:error, reason})
              session_loop(session)
          end
        else
          send(from, {:error, :refresh_not_allowed})
          session_loop(session)
        end

      {:revoke, from} ->
        AuditLog.record(:session_revoked, session.user_id)
        send(from, :ok)
        session_loop(%{session | revoked: true})

      {:get_info, from} ->
        send(from, {:ok, Map.take(session, [:id, :user_id, :revoked, :expires_at])})
        session_loop(session)

      :stop ->
        :ok
    end
  end

  # VALIDATION: SMELL END

  def validate_token(pid, token) do
    send(pid, {:validate, self(), token})

    receive do
      result -> result
    after
      2_000 -> {:error, :timeout}
    end
  end

  def revoke(pid) do
    send(pid, {:revoke, self()})

    receive do
      :ok -> :ok
    after
      2_000 -> {:error, :timeout}
    end
  end

  def get_info(pid) do
    send(pid, {:get_info, self()})

    receive do
      {:ok, info} -> {:ok, info}
    after
      2_000 -> {:error, :timeout}
    end
  end
end
```
