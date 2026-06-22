```elixir
defmodule Events.Ticketing.SeatAllocator do
  @moduledoc """
  Manages seat allocation for ticketed events with zone-based inventory.
  Seats are reserved atomically through a supervised GenServer.
  Expired reservations are released by a periodic sweep.
  """

  use GenServer

  @reservation_ttl_seconds 600
  @sweep_interval_ms 60_000

  @type seat_id :: String.t()
  @type zone_id :: String.t()
  @type reservation_id :: String.t()
  @type seat :: %{id: seat_id(), zone_id: zone_id(), status: :available | :reserved | :sold}
  @type reservation :: %{
          id: reservation_id(),
          seat_ids: [seat_id()],
          holder_id: String.t(),
          expires_at: integer()
        }
  @type state :: %{
          seats: %{seat_id() => seat()},
          reservations: %{reservation_id() => reservation()}
        }

  @doc """
  Starts the SeatAllocator linked to the calling process.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Loads an event's seat map into the allocator.
  """
  @spec load_seats([seat()]) :: :ok | {:error, String.t()}
  def load_seats(seats) when is_list(seats) do
    GenServer.call(__MODULE__, {:load_seats, seats})
  end

  @doc """
  Reserves `count` seats in `zone_id` for `holder_id`.
  Returns `{:ok, reservation_id}` or `{:error, reason}`.
  """
  @spec reserve(zone_id(), pos_integer(), String.t()) ::
          {:ok, reservation_id()} | {:error, :insufficient_seats | String.t()}
  def reserve(zone_id, count, holder_id)
      when is_binary(zone_id) and is_integer(count) and count > 0 and is_binary(holder_id) do
    GenServer.call(__MODULE__, {:reserve, zone_id, count, holder_id})
  end

  @doc """
  Confirms a reservation, marking its seats as sold.
  """
  @spec confirm(reservation_id()) :: :ok | {:error, :not_found | :expired}
  def confirm(reservation_id) when is_binary(reservation_id) do
    GenServer.call(__MODULE__, {:confirm, reservation_id})
  end

  @doc """
  Releases a reservation, returning its seats to available status.
  """
  @spec release(reservation_id()) :: :ok | {:error, :not_found}
  def release(reservation_id) when is_binary(reservation_id) do
    GenServer.call(__MODULE__, {:release, reservation_id})
  end

  @impl GenServer
  def init(_opts) do
    schedule_sweep()
    {:ok, %{seats: %{}, reservations: %{}}}
  end

  @impl GenServer
  def handle_call({:load_seats, seats}, _from, state) do
    seat_map = Enum.into(seats, %{}, fn s -> {s.id, s} end)
    {:reply, :ok, %{state | seats: Map.merge(state.seats, seat_map)}}
  end

  @impl GenServer
  def handle_call({:reserve, zone_id, count, holder_id}, _from, state) do
    available =
      state.seats
      |> Map.values()
      |> Enum.filter(fn s -> s.zone_id == zone_id and s.status == :available end)
      |> Enum.take(count)

    if length(available) < count do
      {:reply, {:error, :insufficient_seats}, state}
    else
      reservation_id = Ecto.UUID.generate()
      seat_ids = Enum.map(available, fn s -> s.id end)
      expires_at = System.system_time(:second) + @reservation_ttl_seconds

      reservation = %{id: reservation_id, seat_ids: seat_ids, holder_id: holder_id, expires_at: expires_at}
      updated_seats = Enum.reduce(seat_ids, state.seats, fn sid, acc ->
        Map.update!(acc, sid, fn s -> %{s | status: :reserved} end)
      end)

      new_state = %{state | seats: updated_seats, reservations: Map.put(state.reservations, reservation_id, reservation)}
      {:reply, {:ok, reservation_id}, new_state}
    end
  end

  @impl GenServer
  def handle_call({:confirm, reservation_id}, _from, state) do
    case Map.fetch(state.reservations, reservation_id) do
      :error ->
        {:reply, {:error, :not_found}, state}

      {:ok, reservation} ->
        if System.system_time(:second) > reservation.expires_at do
          {:reply, {:error, :expired}, state}
        else
          updated_seats = Enum.reduce(reservation.seat_ids, state.seats, fn sid, acc ->
            Map.update!(acc, sid, fn s -> %{s | status: :sold} end)
          end)
          new_reservations = Map.delete(state.reservations, reservation_id)
          {:reply, :ok, %{state | seats: updated_seats, reservations: new_reservations}}
        end
    end
  end

  @impl GenServer
  def handle_call({:release, reservation_id}, _from, state) do
    case Map.fetch(state.reservations, reservation_id) do
      :error ->
        {:reply, {:error, :not_found}, state}

      {:ok, reservation} ->
        new_state = free_reservation(state, reservation)
        {:reply, :ok, new_state}
    end
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    now = System.system_time(:second)

    expired = Enum.filter(state.reservations, fn {_id, r} -> r.expires_at < now end)

    new_state = Enum.reduce(expired, state, fn {_id, reservation}, acc ->
      free_reservation(acc, reservation)
    end)

    schedule_sweep()
    {:noreply, new_state}
  end

  defp free_reservation(state, reservation) do
    updated_seats = Enum.reduce(reservation.seat_ids, state.seats, fn sid, acc ->
      Map.update(acc, sid, nil, fn s -> if s, do: %{s | status: :available}, else: nil end)
    end)
    %{state | seats: updated_seats, reservations: Map.delete(state.reservations, reservation.id)}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end
```
