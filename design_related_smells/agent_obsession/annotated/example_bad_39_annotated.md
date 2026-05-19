# Annotated Example – Bad Code

- **Smell name:** Agent Obsession
- **Expected smell location:** Modules `SessionCreator`, `SessionValidator`, `SessionRevocation`, and `SessionInspector`
- **Affected functions:** `SessionCreator.open/2`, `SessionValidator.valid?/2`, `SessionRevocation.revoke/2`, `SessionInspector.active_for_user/2`
- **Short explanation:** Four separate modules each directly interact with the shared session Agent, scattering read/write logic and the knowledge of the Agent's internal map format across unrelated concerns.

```elixir
defmodule SessionStore do
  @moduledoc "Shared Agent that holds the active session table."

  @ttl_seconds 3600

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{sessions: %{}, revoked: MapSet.new()} end, name: __MODULE__)
  end

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :permanent}
  end

  def default_ttl, do: @ttl_seconds
end

# VALIDATION: SMELL START - Agent Obsession
# VALIDATION: This is a smell because SessionCreator directly calls Agent.update to write
# a new session entry into the Agent, taking implicit ownership of the sessions map format.
defmodule SessionCreator do
  @moduledoc "Issues new authenticated sessions for users."

  require Logger

  def open(agent, %{user_id: user_id, role: role, ip: ip}) do
    token = generate_token()
    ttl = SessionStore.default_ttl()

    session = %{
      token: token,
      user_id: user_id,
      role: role,
      ip: ip,
      issued_at: DateTime.utc_now(),
      expires_at: DateTime.add(DateTime.utc_now(), ttl, :second),
      last_seen: DateTime.utc_now()
    }

    Agent.update(agent, fn state ->
      %{state | sessions: Map.put(state.sessions, token, session)}
    end)

    Logger.info("Session opened for user #{user_id} from #{ip}")
    {:ok, token}
  end

  defp generate_token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end
end
# VALIDATION: SMELL END

# VALIDATION: SMELL START - Agent Obsession
# VALIDATION: This is a smell because SessionValidator directly calls Agent.get and
# Agent.update to both check and refresh session data, duplicating the knowledge of
# how sessions are structured inside the Agent.
defmodule SessionValidator do
  @moduledoc "Validates tokens on incoming requests."

  def valid?(agent, token) do
    now = DateTime.utc_now()

    session = Agent.get(agent, fn state -> Map.get(state.sessions, token) end)
    revoked = Agent.get(agent, fn state -> MapSet.member?(state.revoked, token) end)

    cond do
      is_nil(session) -> {:error, :not_found}
      revoked -> {:error, :revoked}
      DateTime.compare(session.expires_at, now) == :lt -> {:error, :expired}
      true ->
        Agent.update(agent, fn state ->
          updated = %{session | last_seen: now}
          %{state | sessions: Map.put(state.sessions, token, updated)}
        end)

        {:ok, session}
    end
  end
end
# VALIDATION: SMELL END

# VALIDATION: SMELL START - Agent Obsession
# VALIDATION: This is a smell because SessionRevocation directly calls Agent.update to
# move a token into the revoked set, yet another module independently manipulating the
# Agent's internal revoked MapSet without a shared interface.
defmodule SessionRevocation do
  @moduledoc "Revokes sessions on logout or security events."

  require Logger

  def revoke(agent, token) do
    Agent.update(agent, fn state ->
      %{state | revoked: MapSet.put(state.revoked, token)}
    end)

    Logger.info("Session revoked: #{String.slice(token, 0..7)}...")
    :ok
  end

  def revoke_all_for_user(agent, user_id) do
    Agent.update(agent, fn state ->
      user_tokens =
        state.sessions
        |> Map.values()
        |> Enum.filter(&(&1.user_id == user_id))
        |> Enum.map(& &1.token)

      new_revoked = Enum.reduce(user_tokens, state.revoked, &MapSet.put(&2, &1))
      Logger.info("Revoked #{length(user_tokens)} sessions for user #{user_id}")
      %{state | revoked: new_revoked}
    end)

    :ok
  end
end
# VALIDATION: SMELL END

# VALIDATION: SMELL START - Agent Obsession
# VALIDATION: This is a smell because SessionInspector directly calls Agent.get to read
# the raw internal sessions map and filter it, coupling administrative tooling to the
# Agent's internal data representation.
defmodule SessionInspector do
  @moduledoc "Provides administrative views over active sessions."

  def active_for_user(agent, user_id) do
    now = DateTime.utc_now()

    Agent.get(agent, fn state ->
      state.sessions
      |> Map.values()
      |> Enum.filter(fn s ->
        s.user_id == user_id and
          not MapSet.member?(state.revoked, s.token) and
          DateTime.compare(s.expires_at, now) == :gt
      end)
    end)
  end

  def count_active(agent) do
    now = DateTime.utc_now()

    Agent.get(agent, fn state ->
      Enum.count(state.sessions, fn {token, s} ->
        not MapSet.member?(state.revoked, token) and
          DateTime.compare(s.expires_at, now) == :gt
      end)
    end)
  end

  def suspicious_sessions(agent) do
    Agent.get(agent, fn state ->
      state.sessions
      |> Map.values()
      |> Enum.filter(fn s ->
        diff = DateTime.diff(DateTime.utc_now(), s.last_seen, :second)
        diff > 1800
      end)
    end)
  end
end
# VALIDATION: SMELL END
```
