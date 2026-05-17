# Annotated Example 46 — Modules with Identical Names

## Metadata

- **Smell name:** Modules with identical names
- **Expected smell location:** Both `defmodule Session.Manager` declarations
- **Affected functions:** `Session.Manager.create/2`, `Session.Manager.fetch/1`, `Session.Manager.touch/1`, `Session.Manager.destroy/1`, `Session.Manager.active_count/1`
- **Short explanation:** Two different source files both declare `defmodule Session.Manager`. BEAM keeps only one definition per module name; the second file silently replaces the first. Losing session management functions can result in users being unable to log in, sessions never expiring, or security checks being silently bypassed.

---

```elixir
# ── file: lib/session/manager.ex ────────────────────────────────────────────

# VALIDATION: SMELL START - Modules with identical names
# VALIDATION: This is a smell because `Session.Manager` is declared here and
# again in a second block below. BEAM will drop one definition, permanently
# losing session lifecycle functions with serious security implications.

defmodule Session.Manager do
  @moduledoc """
  Manages user sessions: creation, retrieval, renewal, and destruction.
  Defined in `lib/session/manager.ex`.
  """

  alias Session.{Store, Token, DeviceInfo}

  @session_ttl_seconds 86_400
  @idle_timeout_seconds 3_600
  @max_sessions_per_user 5

  @type session_id :: String.t()
  @type user_id :: String.t()

  @type session :: %{
    id: session_id(),
    user_id: user_id(),
    token: String.t(),
    device: map(),
    ip_address: String.t(),
    created_at: DateTime.t(),
    last_active_at: DateTime.t(),
    expires_at: DateTime.t()
  }

  @doc """
  Create a new authenticated session for a user.
  Enforces the per-user session cap, expiring the oldest session if needed.
  """
  @spec create(user_id(), map()) :: {:ok, session()} | {:error, String.t()}
  def create(user_id, request_meta) do
    :ok = maybe_evict_oldest(user_id)

    now = DateTime.utc_now()

    session = %{
      id: generate_id(),
      user_id: user_id,
      token: Token.generate(),
      device: DeviceInfo.from_meta(request_meta),
      ip_address: Map.get(request_meta, :ip_address, "unknown"),
      created_at: now,
      last_active_at: now,
      expires_at: DateTime.add(now, @session_ttl_seconds, :second)
    }

    case Store.save(session) do
      {:ok, saved} -> {:ok, saved}
      {:error, reason} -> {:error, "Failed to persist session: #{inspect(reason)}"}
    end
  end

  @doc "Fetch a session by its ID, checking expiry and idle timeout."
  @spec fetch(session_id()) :: {:ok, session()} | {:error, atom()}
  def fetch(session_id) do
    case Store.get(session_id) do
      {:ok, session} ->
        cond do
          expired?(session) ->
            Store.delete(session_id)
            {:error, :expired}

          idle?(session) ->
            Store.delete(session_id)
            {:error, :idle_timeout}

          true ->
            {:ok, session}
        end

      :not_found ->
        {:error, :not_found}
    end
  end

  @doc "Update the `last_active_at` timestamp to prevent idle timeout."
  @spec touch(session_id()) :: :ok | {:error, atom()}
  def touch(session_id) do
    case fetch(session_id) do
      {:ok, session} ->
        Store.update(session_id, %{last_active_at: DateTime.utc_now()})

      {:error, _} = err ->
        err
    end
  end

  @doc "Invalidate and delete a session immediately."
  @spec destroy(session_id()) :: :ok
  def destroy(session_id) do
    Store.delete(session_id)
    Token.revoke(session_id)
    :ok
  end

  @doc "Return the number of active sessions for a user."
  @spec active_count(user_id()) :: non_neg_integer()
  def active_count(user_id) do
    Store.count(user_id: user_id)
  end

  @doc "Destroy all sessions for a user (e.g., after password change)."
  @spec destroy_all(user_id()) :: {:ok, non_neg_integer()}
  def destroy_all(user_id) do
    sessions = Store.list(user_id: user_id)
    Enum.each(sessions, &destroy(&1.id))
    {:ok, length(sessions)}
  end

  defp expired?(%{expires_at: exp}) do
    DateTime.compare(DateTime.utc_now(), exp) == :gt
  end

  defp idle?(%{last_active_at: last}) do
    elapsed = DateTime.diff(DateTime.utc_now(), last, :second)
    elapsed >= @idle_timeout_seconds
  end

  defp maybe_evict_oldest(user_id) do
    sessions = Store.list(user_id: user_id) |> Enum.sort_by(& &1.created_at)

    if length(sessions) >= @max_sessions_per_user do
      oldest = List.first(sessions)
      destroy(oldest.id)
    end

    :ok
  end

  defp generate_id, do: :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
end

# VALIDATION: SMELL END

# ── file: lib/session/manager_geo_binding.ex  (IP binding security added later;
#    developer accidentally reused the parent module name) ────────────────────

# VALIDATION: SMELL START - Modules with identical names
# VALIDATION: This second `defmodule Session.Manager` replaces the first in
# BEAM. `create/2`, `fetch/1`, `touch/1`, `destroy/1`, and `active_count/1`
# all vanish, making it impossible to create, fetch, or invalidate sessions.

defmodule Session.Manager do
  @moduledoc """
  IP and device binding enforcement for active sessions.
  Was intended to be `Session.Manager.GeoBinder` but was accidentally given
  the same module name as the core session manager.
  """

  alias Session.Store

  @doc "Verify that a session's current IP matches its registered IP."
  @spec verify_ip(String.t(), String.t()) ::
          :ok | {:error, :ip_mismatch}
  def verify_ip(session_id, current_ip) do
    case Store.get(session_id) do
      {:ok, %{ip_address: bound_ip}} ->
        if bound_ip == current_ip, do: :ok, else: {:error, :ip_mismatch}

      :not_found ->
        {:error, :ip_mismatch}
    end
  end

  @doc "Rebind a session to a new IP address (e.g., after legitimate network change)."
  @spec rebind_ip(String.t(), String.t()) :: :ok | {:error, String.t()}
  def rebind_ip(session_id, new_ip) do
    case Store.get(session_id) do
      {:ok, _session} ->
        Store.update(session_id, %{ip_address: new_ip, last_active_at: DateTime.utc_now()})

      :not_found ->
        {:error, "Session not found: #{session_id}"}
    end
  end

  @doc "Return all sessions whose bound IP address has changed since creation."
  @spec suspicious_sessions() :: [map()]
  def suspicious_sessions do
    Store.all()
    |> Enum.filter(fn session ->
      Map.get(session, :current_ip, session.ip_address) != session.ip_address
    end)
  end
end

# VALIDATION: SMELL END
```
