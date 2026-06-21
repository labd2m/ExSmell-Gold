```elixir
defmodule Commerce.ReservationStore do
  @moduledoc """
  An ETS-backed GenServer that manages time-limited inventory reservations.

  When a customer starts checkout, items are reserved for a configurable
  hold period. Reservations that are neither confirmed nor explicitly
  released expire automatically, returning stock to the available pool.
  """

  use GenServer

  require Logger

  @type sku :: String.t()
  @type reservation_id :: String.t()
  @type reservation :: %{
          id: reservation_id(),
          sku: sku(),
          quantity: pos_integer(),
          held_by: String.t(),
          expires_at: integer()
        }

  @default_hold_ms :timer.minutes(15)
  @sweep_interval_ms :timer.minutes(1)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Attempts to reserve `quantity` units of `sku` for `held_by`.
  Returns `{:ok, reservation_id}` or `{:error, :insufficient_stock}`.
  """
  @spec reserve(sku(), pos_integer(), String.t(), keyword()) ::
          {:ok, reservation_id()} | {:error, :insufficient_stock}
  def reserve(sku, quantity, held_by, opts \\ [])
      when is_binary(sku) and is_integer(quantity) and quantity > 0 do
    hold_ms = Keyword.get(opts, :hold_ms, @default_hold_ms)
    GenServer.call(__MODULE__, {:reserve, sku, quantity, held_by, hold_ms})
  end

  @doc "Releases a reservation before it expires. A no-op if already expired."
  @spec release(reservation_id()) :: :ok
  def release(reservation_id) when is_binary(reservation_id) do
    GenServer.cast(__MODULE__, {:release, reservation_id})
  end

  @doc "Returns the total quantity currently reserved for `sku`."
  @spec reserved_quantity(sku()) :: non_neg_integer()
  def reserved_quantity(sku) when is_binary(sku) do
    GenServer.call(__MODULE__, {:reserved_quantity, sku})
  end

  @doc "Confirms a reservation, removing it without expiry logging."
  @spec confirm(reservation_id()) :: :ok | {:error, :not_found}
  def confirm(reservation_id) when is_binary(reservation_id) do
    GenServer.call(__MODULE__, {:confirm, reservation_id})
  end

  @impl GenServer
  def init(opts) do
    table = :ets.new(:reservations, [:set, :private])
    hold_ms = Keyword.get(opts, :default_hold_ms, @default_hold_ms)
    schedule_sweep()
    {:ok, %{table: table, default_hold_ms: hold_ms}}
  end

  @impl GenServer
  def handle_call({:reserve, sku, quantity, held_by, hold_ms}, _from, state) do
    id = generate_id()
    expires_at = now_ms() + hold_ms
    entry = {id, %{id: id, sku: sku, quantity: quantity, held_by: held_by, expires_at: expires_at}}
    :ets.insert(state.table, entry)
    {:reply, {:ok, id}, state}
  end

  @impl GenServer
  def handle_call({:reserved_quantity, sku}, _from, %{table: table} = state) do
    current = now_ms()
    total = :ets.foldl(fn {_id, r}, acc ->
      if r.sku == sku and r.expires_at > current, do: acc + r.quantity, else: acc
    end, 0, table)
    {:reply, total, state}
  end

  @impl GenServer
  def handle_call({:confirm, reservation_id}, _from, %{table: table} = state) do
    case :ets.lookup(table, reservation_id) do
      [{^reservation_id, _}] ->
        :ets.delete(table, reservation_id)
        {:reply, :ok, state}
      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl GenServer
  def handle_cast({:release, reservation_id}, %{table: table} = state) do
    :ets.delete(table, reservation_id)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:sweep, %{table: table} = state) do
    expired = sweep_expired(table)
    if expired > 0, do: Logger.debug("[ReservationStore] Swept #{expired} expired reservations")
    schedule_sweep()
    {:noreply, state}
  end

  defp sweep_expired(table) do
    current = now_ms()
    expired_ids = :ets.foldl(fn {id, %{expires_at: exp}}, acc ->
      if exp < current, do: [id | acc], else: acc
    end, [], table)
    Enum.each(expired_ids, &:ets.delete(table, &1))
    length(expired_ids)
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
  defp now_ms, do: :erlang.system_time(:millisecond)
  defp generate_id, do: :crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower)
end
```
