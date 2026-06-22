```elixir
defmodule Inventory.StockLevel do
  @moduledoc """
  Tracks stock levels and reservation state for a single SKU.
  """

  @type t :: %__MODULE__{
          sku: String.t(),
          on_hand: non_neg_integer(),
          reserved: non_neg_integer()
        }

  defstruct [:sku, :on_hand, :reserved]

  @spec available(%__MODULE__{}) :: non_neg_integer()
  def available(%__MODULE__{on_hand: on_hand, reserved: reserved}) do
    max(on_hand - reserved, 0)
  end
end

defmodule Inventory.Manager do
  use GenServer

  alias Inventory.StockLevel

  @moduledoc """
  Manages concurrent access to warehouse stock levels for a bounded
  set of SKUs. Reservations are two-phase: reserve then confirm or release.
  """

  @type reservation_id :: String.t()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put(opts, :name, __MODULE__))
  end

  @spec load_sku(String.t(), non_neg_integer()) :: :ok
  def load_sku(sku, on_hand) when is_binary(sku) and is_integer(on_hand) and on_hand >= 0 do
    GenServer.cast(__MODULE__, {:load, sku, on_hand})
  end

  @spec reserve(String.t(), pos_integer()) ::
          {:ok, reservation_id()} | {:error, :insufficient_stock | :unknown_sku}
  def reserve(sku, qty) when is_binary(sku) and is_integer(qty) and qty > 0 do
    GenServer.call(__MODULE__, {:reserve, sku, qty})
  end

  @spec confirm(reservation_id()) :: :ok | {:error, :unknown_reservation}
  def confirm(reservation_id) when is_binary(reservation_id) do
    GenServer.call(__MODULE__, {:confirm, reservation_id})
  end

  @spec release(reservation_id()) :: :ok | {:error, :unknown_reservation}
  def release(reservation_id) when is_binary(reservation_id) do
    GenServer.call(__MODULE__, {:release, reservation_id})
  end

  @spec stock_level(String.t()) :: {:ok, StockLevel.t()} | {:error, :unknown_sku}
  def stock_level(sku) when is_binary(sku) do
    GenServer.call(__MODULE__, {:stock_level, sku})
  end

  @impl GenServer
  def init(:ok), do: {:ok, %{levels: %{}, reservations: %{}}}

  @impl GenServer
  def handle_cast({:load, sku, on_hand}, state) do
    level = %StockLevel{sku: sku, on_hand: on_hand, reserved: 0}
    {:noreply, put_in(state.levels[sku], level)}
  end

  @impl GenServer
  def handle_call({:reserve, sku, qty}, _from, state) do
    case Map.fetch(state.levels, sku) do
      :error ->
        {:reply, {:error, :unknown_sku}, state}

      {:ok, level} when StockLevel.available(level) < qty ->
        {:reply, {:error, :insufficient_stock}, state}

      {:ok, level} ->
        reservation_id = generate_id()
        updated_level = %{level | reserved: level.reserved + qty}
        new_state =
          state
          |> put_in([:levels, sku], updated_level)
          |> put_in([:reservations, reservation_id], {sku, qty})

        {:reply, {:ok, reservation_id}, new_state}
    end
  end

  def handle_call({:confirm, reservation_id}, _from, state) do
    case Map.fetch(state.reservations, reservation_id) do
      :error ->
        {:reply, {:error, :unknown_reservation}, state}

      {:ok, {sku, qty}} ->
        level = state.levels[sku]
        updated = %{level | on_hand: level.on_hand - qty, reserved: level.reserved - qty}
        new_state =
          state
          |> put_in([:levels, sku], updated)
          |> Map.update!(:reservations, &Map.delete(&1, reservation_id))

        {:reply, :ok, new_state}
    end
  end

  def handle_call({:release, reservation_id}, _from, state) do
    case Map.fetch(state.reservations, reservation_id) do
      :error ->
        {:reply, {:error, :unknown_reservation}, state}

      {:ok, {sku, qty}} ->
        level = state.levels[sku]
        updated = %{level | reserved: level.reserved - qty}
        new_state =
          state
          |> put_in([:levels, sku], updated)
          |> Map.update!(:reservations, &Map.delete(&1, reservation_id))

        {:reply, :ok, new_state}
    end
  end

  def handle_call({:stock_level, sku}, _from, state) do
    case Map.fetch(state.levels, sku) do
      {:ok, level} -> {:reply, {:ok, level}, state}
      :error -> {:reply, {:error, :unknown_sku}, state}
    end
  end

  defp generate_id do
    :crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower)
  end
end
```
