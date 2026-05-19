# Annotated Example — GenServer Envy

- **Smell name:** GenServer Envy
- **Expected smell location:** `UserSessionAgent` module — `Agent` running session management logic
- **Affected function(s):** `authenticate/2`, `refresh_session/2`, `invalidate_session/1`, `prune_expired/0`
- **Short explanation:** Instead of merely sharing session state, this `Agent` executes authentication logic, JWT generation, and expiry pruning — complex workflows that exceed an Agent's intended role.

```elixir
defmodule MyApp.UserSessionAgent do
  @moduledoc """
  Provides in-memory session management with authentication, refresh,
  and expiry handling for web request pipelines.
  """

  use Agent

  alias MyApp.{Repo, JWTService, PasswordHasher}
  alias MyApp.Accounts.{User, Session}

  @session_ttl_minutes 60
  @max_sessions_per_user 5

  def start_link(_opts) do
    Agent.start_link(fn -> %{sessions: %{}, user_sessions: %{}} end, name: __MODULE__)
  end

  def get_session(token) do
    Agent.get(__MODULE__, fn state -> Map.get(state.sessions, token) end)
  end

  # VALIDATION: SMELL START - GenServer Envy
  # VALIDATION: This is a smell because the Agent is used to perform authentication
  # (password verification, JWT minting) and session lifecycle management — complex
  # business logic involving external calls and multi-step state transitions.
  # An Agent should only be used to share state; this work belongs in a GenServer.

  def authenticate(email, password) do
    Agent.get_and_update(__MODULE__, fn state ->
      with {:ok, user} <- Repo.get_by(User, email: email),
           true <- PasswordHasher.verify(password, user.password_hash),
           {:ok, token, claims} <- JWTService.generate(user.id) do
        session = %Session{
          token: token,
          user_id: user.id,
          claims: claims,
          created_at: DateTime.utc_now(),
          expires_at: DateTime.add(DateTime.utc_now(), @session_ttl_minutes * 60, :second),
          ip_address: nil
        }

        user_sessions = Map.get(state.user_sessions, user.id, [])

        {pruned_state, user_sessions} =
          if length(user_sessions) >= @max_sessions_per_user do
            oldest_token = List.last(user_sessions)

            pruned_sessions = Map.delete(state.sessions, oldest_token)
            pruned_user_list = List.delete(user_sessions, oldest_token)
            {%{state | sessions: pruned_sessions}, pruned_user_list}
          else
            {state, user_sessions}
          end

        new_sessions = Map.put(pruned_state.sessions, token, session)
        new_user_sessions = Map.put(pruned_state.user_sessions, user.id, [token | user_sessions])

        new_state = %{pruned_state | sessions: new_sessions, user_sessions: new_user_sessions}
        {{:ok, session}, new_state}
      else
        _ -> {{:error, :invalid_credentials}, state}
      end
    end)
  end

  def refresh_session(old_token, ip_address) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.fetch(state.sessions, old_token) do
        :error ->
          {{:error, :session_not_found}, state}

        {:ok, session} ->
          now = DateTime.utc_now()

          if DateTime.compare(session.expires_at, now) == :lt do
            new_sessions = Map.delete(state.sessions, old_token)
            {{:error, :session_expired}, %{state | sessions: new_sessions}}
          else
            case JWTService.generate(session.user_id) do
              {:ok, new_token, new_claims} ->
                new_session = %{
                  session
                  | token: new_token,
                    claims: new_claims,
                    ip_address: ip_address,
                    expires_at: DateTime.add(now, @session_ttl_minutes * 60, :second)
                }

                user_tokens = Map.get(state.user_sessions, session.user_id, [])
                updated_user_tokens = [new_token | List.delete(user_tokens, old_token)]

                new_state = %{
                  state
                  | sessions:
                      state.sessions
                      |> Map.delete(old_token)
                      |> Map.put(new_token, new_session),
                    user_sessions:
                      Map.put(state.user_sessions, session.user_id, updated_user_tokens)
                }

                {{:ok, new_session}, new_state}

              {:error, reason} ->
                {{:error, reason}, state}
            end
          end
      end
    end)
  end

  def invalidate_session(token) do
    Agent.update(__MODULE__, fn state ->
      case Map.fetch(state.sessions, token) do
        :error ->
          state

        {:ok, session} ->
          user_tokens =
            state.user_sessions
            |> Map.get(session.user_id, [])
            |> List.delete(token)

          %{
            state
            | sessions: Map.delete(state.sessions, token),
              user_sessions: Map.put(state.user_sessions, session.user_id, user_tokens)
          }
      end
    end)
  end

  def prune_expired do
    now = DateTime.utc_now()

    Agent.update(__MODULE__, fn state ->
      {active, _expired} =
        Enum.split_with(state.sessions, fn {_token, session} ->
          DateTime.compare(session.expires_at, now) in [:gt, :eq]
        end)

      active_sessions = Map.new(active)

      active_user_sessions =
        Map.new(state.user_sessions, fn {uid, tokens} ->
          {uid, Enum.filter(tokens, &Map.has_key?(active_sessions, &1))}
        end)

      %{state | sessions: active_sessions, user_sessions: active_user_sessions}
    end)
  end

  # VALIDATION: SMELL END
end
```
