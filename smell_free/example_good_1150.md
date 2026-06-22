```elixir
defmodule Cache.SessionStore do
  @moduledoc """
  Centralized in-memory session store backed by an Agent process.

  All Agent interactions are encapsulated behind a typed public API.
  No external module accesses the agent state directly. Session entries
  carry an expiry timestamp and are lazily evaluated on read or eagerly
  evicted by calling `purge_expired/0`.

  Start this module under your application supervisor before use:

      children = [Cache.SessionStore]
  """
  use Agent

  @type session_id :: String.t()
  @type session_data :: map()
  @type entry :: %{data: session_data(), expires_at: integer()}
  @type store_state :: %{optional(session_id()) => entry()}

  @default_ttl_seconds 3_600

  # ── Public API ────────────────────────────────────────────────────────────────

  @doc "Starts the session store agent and registers it under its module name."
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @doc """
  Inserts or replaces session data under `session_id`.

  The entry expires after `ttl_seconds` seconds (default: #{@default_ttl_seconds}).
  """
  @spec put(session_id(), session_data(), pos_integer()) :: :ok
  def put(session_id, data, ttl_seconds \\ @default_ttl_seconds)
      when is_binary(session_id) and is_map(data) and is_integer(ttl_seconds) and ttl_seconds > 0 do
    entry = %{data: data, expires_at: unix_now() + ttl_seconds}
    Agent.update(__MODULE__, &Map.put(&1, session_id, entry))
  end

  @doc """
  Retrieves live session data for `session_id`.

  Returns `{:error, :not_found}` when the key is absent, or
  `{:error, :expired}` when the entry exists but its TTL has elapsed.
  """
  @spec get(session_id()) :: {:ok, session_data()} | {:error, :not_found | :expired}
  def get(session_id) when is_binary(session_id) do
    case Agent.get(__MODULE__, &Map.fetch(&1, session_id)) do
      :error -> {:error, :not_found}
      {:ok, entry} -> evaluate_expiry(entry)
    end
  end

  @doc "Removes the session identified by `session_id` from the store."
  @spec delete(session_id()) :: :ok
  def delete(session_id) when is_binary(session_id) do
    Agent.update(__MODULE__, &Map.delete(&1, session_id))
  end

  @doc """
  Extends the TTL for a live session without altering its data.

  Returns `{:error, :not_found}` or `{:error, :expired}` when the session
  cannot be renewed.
  """
  @spec touch(session_id(), pos_integer()) :: :ok | {:error, :not_found | :expired}
  def touch(session_id, ttl_seconds \\ @default_ttl_seconds)
      when is_binary(session_id) and is_integer(ttl_seconds) and ttl_seconds > 0 do
    case get(session_id) do
      {:ok, data} -> put(session_id, data, ttl_seconds)
      error -> error
    end
  end

  @doc """
  Removes all expired entries from the store.

  Returns the count of evicted entries.
  """
  @spec purge_expired() :: non_neg_integer()
  def purge_expired do
    now = unix_now()

    Agent.get_and_update(__MODULE__, fn store ->
      {live, stale} = Enum.split_with(store, fn {_id, entry} -> entry.expires_at > now end)
      evicted_count = length(stale)
      {evicted_count, Map.new(live)}
    end)
  end

  @doc "Returns the total number of entries currently held in the store."
  @spec count() :: non_neg_integer()
  def count do
    Agent.get(__MODULE__, &map_size/1)
  end

  # ── Private helpers ───────────────────────────────────────────────────────────

  defp evaluate_expiry(%{data: data, expires_at: expires_at}) do
    if expires_at > unix_now() do
      {:ok, data}
    else
      {:error, :expired}
    end
  end

  defp unix_now, do: System.os_time(:second)
end
```
