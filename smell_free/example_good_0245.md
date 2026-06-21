# File: `example_good_245.md`

```elixir
defmodule Routing.SlotAllocator do
  @moduledoc """
  GenServer that manages concurrent time-slot reservations for a shared
  resource (e.g. appointment booking, server capacity windows).

  Each slot has a fixed capacity. Reservations are held in memory and
  automatically released when their hold expiry elapses, preventing
  abandoned reservations from blocking other callers.
  """

  use GenServer

  @default_hold_ttl_s 300
  @sweep_interval_ms 60_000

  @type slot_key :: {Date.t(), non_neg_integer()}
  @type reservation_id :: String.t()
  @type holder_id :: String.t()

  @type reservation :: %{
          id: reservation_id(),
          holder_id: holder_id(),
          slot_key: slot_key(),
          held_until: integer()
        }

  @type opts :: [
          slot_capacity: pos_integer(),
          hold_ttl_s: pos_integer()
        ]

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Attempts to reserve a slot at `{date, hour}` for `holder_id`.

  Returns `{:ok, reservation_id}` if capacity is available, or
  `{:error, :slot_full}` when the slot is at capacity.
  """
  @spec reserve(Date.t(), non_neg_integer(), holder_id()) ::
          {:ok, reservation_id()} | {:error, :slot_full}
  def reserve(%Date{} = date, hour, holder_id)
      when is_integer(hour) and hour in 0..23 and is_binary(holder_id) do
    GenServer.call(__MODULE__, {:reserve, {date, hour}, holder_id})
  end

  @doc """
  Confirms a held reservation, extending it to a permanent booking.

  Returns `:ok` or `{:error, :not_found}` if the reservation ID is unknown
  or has expired.
  """
  @spec confirm(reservation_id()) :: :ok | {:error, :not_found | :expired}
  def confirm(reservation_id) when is_binary(reservation_id) do
    GenServer.call(__MODULE__, {:confirm, reservation_id})
  end

  @doc """
  Releases a reservation immediately, freeing capacity in its slot.
  """
  @spec release(reservation_id()) :: :ok
  def release(reservation_id) when is_binary(reservation_id) do
    GenServer.cast(__MODULE__, {:release, reservation_id})
  end

  @doc """
  Returns the number of active reservations in a given slot.
  """
  @spec occupancy(Date.t(), non_neg_integer()) :: non_neg_integer()
  def occupancy(%Date{} = date, hour) when is_integer(hour) do
    GenServer.call(__MODULE__, {:occupancy, {date, hour}})
  end

  @impl GenServer
  def init(opts) do
    capacity = Keyword.get(opts, :slot_capacity, 1)
    hold_ttl_s = Keyword.get(opts, :hold_ttl_s, @default_hold_ttl_s)
    schedule_sweep()
    {:ok, %{reservations: %{}, confirmed: MapSet.new(), capacity: capacity, hold_ttl_s: hold_ttl_s}}
  end

  @impl GenServer
  def handle_call({:reserve, slot_key, holder_id}, _from, state) do
    active = active_count_for_slot(state, slot_key)

    if active >= state.capacity do
      {:reply, {:error, :slot_full}, state}
    else
      reservation_id = generate_id()
      held_until = System.system_time(:second) + state.hold_ttl_s

      res = %{id: reservation_id, holder_id: holder_id, slot_key: slot_key, held_until: held_until}
      new_state = put_in(state, [:reservations, reservation_id], res)
      {:reply, {:ok, reservation_id}, new_state}
    end
  end

  @impl GenServer
  def handle_call({:confirm, reservation_id}, _from, state) do
    now = System.system_time(:second)

    case Map.fetch(state.reservations, reservation_id) do
      {:ok, %{held_until: exp}} when exp > now ->
        new_state = %{state | confirmed: MapSet.put(state.confirmed, reservation_id)}
        {:reply, :ok, new_state}

      {:ok, _expired} ->
        new_state = update_in(state, [:reservations], &Map.delete(&1, reservation_id))
        {:reply, {:error, :expired}, new_state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl GenServer
  def handle_call({:occupancy, slot_key}, _from, state) do
    {:reply, active_count_for_slot(state, slot_key), state}
  end

  @impl GenServer
  def handle_cast({:release, reservation_id}, state) do
    new_state = %{
      state
      | reservations: Map.delete(state.reservations, reservation_id),
        confirmed: MapSet.delete(state.confirmed, reservation_id)
    }

    {:noreply, new_state}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    now = System.system_time(:second)

    live =
      Map.reject(state.reservations, fn {id, res} ->
        not MapSet.member?(state.confirmed, id) and res.held_until <= now
      end)

    schedule_sweep()
    {:noreply, %{state | reservations: live}}
  end

  defp active_count_for_slot(state, slot_key) do
    Enum.count(state.reservations, fn {_id, res} -> res.slot_key == slot_key end)
  end

  defp generate_id do
    :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end
end
```
