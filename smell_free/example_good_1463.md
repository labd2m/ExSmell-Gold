```elixir
defmodule Cache.Entry do
  @moduledoc false

  @type t :: %__MODULE__{value: term(), expires_at: integer()}
  defstruct [:value, :expires_at]
end

defmodule Cache.Store do
  use GenServer

  alias Cache.Entry

  @moduledoc """
  An in-memory key-value cache with per-entry TTL enforcement.
  Expired entries are lazily evicted on read and eagerly swept by
  a periodic background pass to prevent unbounded memory growth.
  """

  @sweep_interval_ms 30_000

  @type key :: term()
  @type value :: term()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, :ok, name: name)
  end

  @spec put(GenServer.server(), key(), value(), pos_integer()) :: :ok
  def put(server \\ __MODULE__, key, value, ttl_seconds)
      when is_integer(ttl_seconds) and ttl_seconds > 0 do
    GenServer.cast(server, {:put, key, value, ttl_seconds})
  end

  @spec get(GenServer.server(), key()) :: {:ok, value()} | {:error, :not_found | :expired}
  def get(server \\ __MODULE__, key) do
    GenServer.call(server, {:get, key})
  end

  @spec delete(GenServer.server(), key()) :: :ok
  def delete(server \\ __MODULE__, key) do
    GenServer.cast(server, {:delete, key})
  end

  @spec size(GenServer.server()) :: non_neg_integer()
  def size(server \\ __MODULE__) do
    GenServer.call(server, :size)
  end

  @impl GenServer
  def init(:ok) do
    schedule_sweep()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_cast({:put, key, value, ttl}, state) do
    expires_at = System.monotonic_time(:second) + ttl
    entry = %Entry{value: value, expires_at: expires_at}
    {:noreply, Map.put(state, key, entry)}
  end

  def handle_cast({:delete, key}, state) do
    {:noreply, Map.delete(state, key)}
  end

  @impl GenServer
  def handle_call({:get, key}, _from, state) do
    now = System.monotonic_time(:second)

    case Map.fetch(state, key) do
      {:ok, %Entry{expires_at: exp}} when exp <= now ->
        {:reply, {:error, :expired}, Map.delete(state, key)}

      {:ok, %Entry{value: value}} ->
        {:reply, {:ok, value}, state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:size, _from, state) do
    {:reply, map_size(state), state}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:second)

    alive =
      state
      |> Enum.reject(fn {_k, %Entry{expires_at: exp}} -> exp <= now end)
      |> Map.new()

    schedule_sweep()
    {:noreply, alive}
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end
end
```
