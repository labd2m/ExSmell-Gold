```elixir
defmodule Payments.IdempotencyKeyStore do
  @moduledoc """
  Tracks payment request idempotency keys to prevent duplicate charges.
  When a key is seen for the first time the store reserves it and returns
  `{:ok, :new}`. Subsequent requests with the same key return the original
  cached result. Keys expire after a configurable TTL so the store does
  not grow unbounded.
  """

  use GenServer

  @type idempotency_key :: String.t()
  @type cached_result :: term()
  @type lookup_result ::
          {:ok, :new}
          | {:ok, :duplicate, cached_result()}
          | {:error, :key_in_flight}

  @default_ttl_ms :timer.hours(24)
  @sweep_interval_ms :timer.minutes(30)

  @doc "Starts the idempotency key store."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Checks whether `key` has been seen before. Returns `:new` on first use,
  `:duplicate` with the cached result on subsequent calls, or
  `:key_in_flight` if the key is reserved but no result has been stored yet.
  """
  @spec check(idempotency_key()) :: lookup_result()
  def check(key) when is_binary(key) do
    GenServer.call(__MODULE__, {:check, key})
  end

  @doc "Stores the result for a completed request identified by `key`."
  @spec complete(idempotency_key(), cached_result()) :: :ok
  def complete(key, result) when is_binary(key) do
    GenServer.cast(__MODULE__, {:complete, key, result})
  end

  @doc "Forcibly releases a reserved key, e.g. after a fatal error."
  @spec release(idempotency_key()) :: :ok
  def release(key) when is_binary(key) do
    GenServer.cast(__MODULE__, {:release, key})
  end

  @impl GenServer
  def init(opts) do
    ttl = Keyword.get(opts, :ttl_ms, @default_ttl_ms)
    sweep = Keyword.get(opts, :sweep_interval_ms, @sweep_interval_ms)
    Process.send_after(self(), :sweep, sweep)
    {:ok, %{entries: %{}, ttl: ttl, sweep_interval: sweep}}
  end

  @impl GenServer
  def handle_call({:check, key}, _from, state) do
    now = System.monotonic_time(:millisecond)

    {reply, new_entries} =
      case Map.get(state.entries, key) do
        nil ->
          entry = %{status: :in_flight, result: nil, reserved_at: now}
          {{:ok, :new}, Map.put(state.entries, key, entry)}

        %{status: :in_flight} ->
          {{:error, :key_in_flight}, state.entries}

        %{status: :complete, result: result} ->
          {{:ok, :duplicate, result}, state.entries}
      end

    {:reply, reply, %{state | entries: new_entries}}
  end

  @impl GenServer
  def handle_cast({:complete, key, result}, state) do
    new_entries = Map.update(state.entries, key, %{}, fn e -> %{e | status: :complete, result: result} end)
    {:noreply, %{state | entries: new_entries}}
  end

  def handle_cast({:release, key}, state) do
    {:noreply, %{state | entries: Map.delete(state.entries, key)}}
  end

  @impl GenServer
  def handle_info(:sweep, %{ttl: ttl, sweep_interval: sweep_interval} = state) do
    cutoff = System.monotonic_time(:millisecond) - ttl
    live = Map.reject(state.entries, fn {_k, e} -> e.reserved_at < cutoff end)
    Process.send_after(self(), :sweep, sweep_interval)
    {:noreply, %{state | entries: live}}
  end
end
```
