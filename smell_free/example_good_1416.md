```elixir
defmodule Collaboration.Documents.LockManager do
  @moduledoc """
  Manages exclusive edit locks on collaborative documents.
  A lock grants the holder sole write access for its duration.
  Locks expire automatically and may be explicitly released or extended.
  """

  use GenServer

  @default_lock_ttl_seconds 120
  @sweep_interval_ms 30_000

  @type doc_id :: String.t()
  @type holder_id :: String.t()
  @type lock :: %{
          doc_id: doc_id(),
          holder_id: holder_id(),
          acquired_at: DateTime.t(),
          expires_at: integer()
        }
  @type state :: %{locks: %{doc_id() => lock()}, ttl_seconds: pos_integer()}

  @doc """
  Starts the LockManager linked to the calling process.

  ## Options
    - `:ttl_seconds` - lock lifetime in seconds (default: 120)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Acquires an exclusive lock on `doc_id` for `holder_id`.
  Returns `{:ok, lock}` or `{:error, :already_locked}` if held by another.
  """
  @spec acquire(doc_id(), holder_id(), keyword()) ::
          {:ok, lock()} | {:error, :already_locked | String.t()}
  def acquire(doc_id, holder_id, opts \\ [])
      when is_binary(doc_id) and is_binary(holder_id) do
    ttl_override = Keyword.get(opts, :ttl_seconds)
    GenServer.call(__MODULE__, {:acquire, doc_id, holder_id, ttl_override})
  end

  @doc """
  Releases a lock held by `holder_id` on `doc_id`.
  Returns `{:error, :not_held}` if the lock is held by another party.
  """
  @spec release(doc_id(), holder_id()) :: :ok | {:error, :not_found | :not_held}
  def release(doc_id, holder_id) when is_binary(doc_id) and is_binary(holder_id) do
    GenServer.call(__MODULE__, {:release, doc_id, holder_id})
  end

  @doc """
  Extends the lock TTL for `holder_id` on `doc_id` by `extra_seconds`.
  """
  @spec extend(doc_id(), holder_id(), pos_integer()) ::
          {:ok, lock()} | {:error, :not_found | :not_held | :expired}
  def extend(doc_id, holder_id, extra_seconds)
      when is_binary(doc_id) and is_binary(holder_id) and
             is_integer(extra_seconds) and extra_seconds > 0 do
    GenServer.call(__MODULE__, {:extend, doc_id, holder_id, extra_seconds})
  end

  @doc """
  Returns the current lock on `doc_id`, or `{:error, :not_found}` if unlocked.
  """
  @spec fetch(doc_id()) :: {:ok, lock()} | {:error, :not_found | :expired}
  def fetch(doc_id) when is_binary(doc_id) do
    GenServer.call(__MODULE__, {:fetch, doc_id})
  end

  @impl GenServer
  def init(opts) do
    ttl = Keyword.get(opts, :ttl_seconds, @default_lock_ttl_seconds)
    schedule_sweep()
    {:ok, %{locks: %{}, ttl_seconds: ttl}}
  end

  @impl GenServer
  def handle_call({:acquire, doc_id, holder_id, ttl_override}, _from, state) do
    ttl = ttl_override || state.ttl_seconds
    now = System.system_time(:second)

    case Map.fetch(state.locks, doc_id) do
      {:ok, existing} when existing.expires_at > now and existing.holder_id != holder_id ->
        {:reply, {:error, :already_locked}, state}

      _ ->
        lock = %{
          doc_id: doc_id,
          holder_id: holder_id,
          acquired_at: DateTime.utc_now(),
          expires_at: now + ttl
        }

        {:reply, {:ok, lock}, %{state | locks: Map.put(state.locks, doc_id, lock)}}
    end
  end

  @impl GenServer
  def handle_call({:release, doc_id, holder_id}, _from, state) do
    case Map.fetch(state.locks, doc_id) do
      :error ->
        {:reply, {:error, :not_found}, state}

      {:ok, %{holder_id: ^holder_id}} ->
        {:reply, :ok, %{state | locks: Map.delete(state.locks, doc_id)}}

      {:ok, _} ->
        {:reply, {:error, :not_held}, state}
    end
  end

  @impl GenServer
  def handle_call({:extend, doc_id, holder_id, extra_seconds}, _from, state) do
    now = System.system_time(:second)

    case Map.fetch(state.locks, doc_id) do
      :error ->
        {:reply, {:error, :not_found}, state}

      {:ok, %{holder_id: h}} when h != holder_id ->
        {:reply, {:error, :not_held}, state}

      {:ok, %{expires_at: exp}} when exp <= now ->
        {:reply, {:error, :expired}, state}

      {:ok, lock} ->
        updated = %{lock | expires_at: lock.expires_at + extra_seconds}
        {:reply, {:ok, updated}, %{state | locks: Map.put(state.locks, doc_id, updated)}}
    end
  end

  @impl GenServer
  def handle_call({:fetch, doc_id}, _from, state) do
    now = System.system_time(:second)

    case Map.fetch(state.locks, doc_id) do
      :error ->
        {:reply, {:error, :not_found}, state}

      {:ok, %{expires_at: exp}} when exp <= now ->
        {:reply, {:error, :expired}, state}

      {:ok, lock} ->
        {:reply, {:ok, lock}, state}
    end
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    now = System.system_time(:second)
    remaining = Map.reject(state.locks, fn {_id, lock} -> lock.expires_at <= now end)
    schedule_sweep()
    {:noreply, %{state | locks: remaining}}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end
```
