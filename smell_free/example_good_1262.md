```elixir
defmodule Cache.TTLStore do
  @moduledoc """
  An in-memory key-value cache backed by a named ETS table with per-entry TTL.
  A supervised sweep process periodically evicts expired entries.
  """

  use GenServer

  @default_ttl_ms 60_000
  @sweep_interval_ms 30_000

  @type key :: term()
  @type value :: term()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec put(atom(), key(), value(), pos_integer()) :: :ok
  def put(name \\ __MODULE__, key, value, ttl_ms \\ @default_ttl_ms)
      when is_atom(name) and is_integer(ttl_ms) and ttl_ms > 0 do
    expires_at = System.monotonic_time(:millisecond) + ttl_ms
    :ets.insert(ets_table(name), {key, value, expires_at})
    :ok
  end

  @spec get(atom(), key()) :: {:ok, value()} | {:error, :not_found}
  def get(name \\ __MODULE__, key) when is_atom(name) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(ets_table(name), key) do
      [{^key, value, expires_at}] when expires_at > now -> {:ok, value}
      _ -> {:error, :not_found}
    end
  end

  @spec fetch_or_store(atom(), key(), (-> value()), pos_integer()) :: {:ok, value()}
  def fetch_or_store(name \\ __MODULE__, key, fun, ttl_ms \\ @default_ttl_ms)
      when is_atom(name) and is_function(fun, 0) do
    case get(name, key) do
      {:ok, _} = hit ->
        hit

      {:error, :not_found} ->
        value = fun.()
        put(name, key, value, ttl_ms)
        {:ok, value}
    end
  end

  @spec delete(atom(), key()) :: :ok
  def delete(name \\ __MODULE__, key) when is_atom(name) do
    :ets.delete(ets_table(name), key)
    :ok
  end

  @spec flush(atom()) :: :ok
  def flush(name \\ __MODULE__) when is_atom(name) do
    :ets.delete_all_objects(ets_table(name))
    :ok
  end

  @spec size(atom()) :: non_neg_integer()
  def size(name \\ __MODULE__) when is_atom(name) do
    :ets.info(ets_table(name), :size)
  end

  @impl GenServer
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    table = ets_table(name)
    :ets.new(table, [:named_table, :public, :set, read_concurrency: true])
    schedule_sweep()
    {:ok, %{table: table}}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)
    :ets.select_delete(state.table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end

  defp ets_table(name), do: :"#{name}.Table"
end
```
