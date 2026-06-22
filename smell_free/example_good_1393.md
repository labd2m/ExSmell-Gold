```elixir
defmodule Telehealth.Appointments.SlotReserver do
  @moduledoc """
  Manages appointment slot reservations for telehealth consultations.
  Slots are reserved atomically with a short-lived hold before confirmation.
  Expired holds are released by a periodic sweep, returning slots to availability.
  """

  use GenServer

  @hold_ttl_seconds 300
  @sweep_interval_ms 60_000

  @type slot_id :: String.t()
  @type provider_id :: String.t()
  @type patient_id :: String.t()
  @type hold_id :: String.t()
  @type slot_status :: :available | :on_hold | :confirmed | :cancelled
  @type slot :: %{
          id: slot_id(),
          provider_id: provider_id(),
          starts_at: DateTime.t(),
          duration_minutes: pos_integer(),
          status: slot_status(),
          held_by: patient_id() | nil,
          hold_expires_at: integer() | nil,
          confirmed_by: patient_id() | nil
        }
  @type state :: %{slots: %{slot_id() => slot()}}

  @doc """
  Starts the SlotReserver linked to the calling process.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Adds available appointment slots to the reserver.
  """
  @spec load_slots([slot()]) :: :ok | {:error, String.t()}
  def load_slots(slots) when is_list(slots) do
    case validate_slots(slots) do
      :ok -> GenServer.call(__MODULE__, {:load_slots, slots})
      {:error, _} = err -> err
    end
  end

  @doc """
  Places a short-lived hold on `slot_id` for `patient_id`.
  Returns `{:ok, hold_id}` or `{:error, reason}`.
  """
  @spec hold(slot_id(), patient_id()) :: {:ok, hold_id()} | {:error, :not_available | :not_found}
  def hold(slot_id, patient_id) when is_binary(slot_id) and is_binary(patient_id) do
    GenServer.call(__MODULE__, {:hold, slot_id, patient_id})
  end

  @doc """
  Confirms a held slot, converting it to a confirmed appointment.
  """
  @spec confirm(slot_id(), patient_id()) ::
          :ok | {:error, :not_found | :not_held_by_patient | :hold_expired}
  def confirm(slot_id, patient_id) when is_binary(slot_id) and is_binary(patient_id) do
    GenServer.call(__MODULE__, {:confirm, slot_id, patient_id})
  end

  @doc """
  Cancels a confirmed or held slot.
  """
  @spec cancel(slot_id(), patient_id()) :: :ok | {:error, :not_found | :not_authorised}
  def cancel(slot_id, patient_id) when is_binary(slot_id) and is_binary(patient_id) do
    GenServer.call(__MODULE__, {:cancel, slot_id, patient_id})
  end

  @doc """
  Returns all available slots for `provider_id` after `from_dt`.
  """
  @spec available_for_provider(provider_id(), DateTime.t()) :: [slot()]
  def available_for_provider(provider_id, %DateTime{} = from_dt) when is_binary(provider_id) do
    GenServer.call(__MODULE__, {:available_for_provider, provider_id, from_dt})
  end

  @impl GenServer
  def init(_opts) do
    schedule_sweep()
    {:ok, %{slots: %{}}}
  end

  @impl GenServer
  def handle_call({:load_slots, slots}, _from, state) do
    new_slots = Enum.into(slots, %{}, fn s -> {s.id, s} end)
    {:reply, :ok, %{state | slots: Map.merge(state.slots, new_slots)}}
  end

  @impl GenServer
  def handle_call({:hold, slot_id, patient_id}, _from, state) do
    case Map.fetch(state.slots, slot_id) do
      :error ->
        {:reply, {:error, :not_found}, state}

      {:ok, %{status: :available} = slot} ->
        hold_id = Ecto.UUID.generate()
        expires_at = System.system_time(:second) + @hold_ttl_seconds
        updated = %{slot | status: :on_hold, held_by: patient_id, hold_expires_at: expires_at}
        {:reply, {:ok, hold_id}, %{state | slots: Map.put(state.slots, slot_id, updated)}}

      {:ok, _} ->
        {:reply, {:error, :not_available}, state}
    end
  end

  @impl GenServer
  def handle_call({:confirm, slot_id, patient_id}, _from, state) do
    case Map.fetch(state.slots, slot_id) do
      :error ->
        {:reply, {:error, :not_found}, state}

      {:ok, %{status: :on_hold, held_by: ^patient_id, hold_expires_at: exp} = slot} ->
        if System.system_time(:second) > exp do
          {:reply, {:error, :hold_expired}, state}
        else
          updated = %{slot | status: :confirmed, confirmed_by: patient_id, hold_expires_at: nil}
          {:reply, :ok, %{state | slots: Map.put(state.slots, slot_id, updated)}}
        end

      {:ok, %{status: :on_hold}} ->
        {:reply, {:error, :not_held_by_patient}, state}

      {:ok, _} ->
        {:reply, {:error, :not_held_by_patient}, state}
    end
  end

  @impl GenServer
  def handle_call({:cancel, slot_id, patient_id}, _from, state) do
    case Map.fetch(state.slots, slot_id) do
      :error ->
        {:reply, {:error, :not_found}, state}

      {:ok, %{held_by: ^patient_id} = slot} ->
        updated = %{slot | status: :cancelled, held_by: nil, hold_expires_at: nil}
        {:reply, :ok, %{state | slots: Map.put(state.slots, slot_id, updated)}}

      {:ok, %{confirmed_by: ^patient_id} = slot} ->
        updated = %{slot | status: :cancelled, confirmed_by: nil}
        {:reply, :ok, %{state | slots: Map.put(state.slots, slot_id, updated)}}

      {:ok, _} ->
        {:reply, {:error, :not_authorised}, state}
    end
  end

  @impl GenServer
  def handle_call({:available_for_provider, provider_id, from_dt}, _from, state) do
    results =
      state.slots
      |> Map.values()
      |> Enum.filter(fn s ->
        s.provider_id == provider_id and
          s.status == :available and
          DateTime.compare(s.starts_at, from_dt) != :lt
      end)
      |> Enum.sort_by(fn s -> s.starts_at end, DateTime)

    {:reply, results, state}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    now = System.system_time(:second)

    updated_slots =
      Map.new(state.slots, fn {id, slot} ->
        if slot.status == :on_hold and is_integer(slot.hold_expires_at) and slot.hold_expires_at < now do
          {id, %{slot | status: :available, held_by: nil, hold_expires_at: nil}}
        else
          {id, slot}
        end
      end)

    schedule_sweep()
    {:noreply, %{state | slots: updated_slots}}
  end

  defp validate_slots(slots) do
    invalid = Enum.find(slots, fn s -> not valid_slot?(s) end)

    if is_nil(invalid) do
      :ok
    else
      {:error, "invalid slot: #{inspect(invalid)}"}
    end
  end

  defp valid_slot?(%{id: id, provider_id: pid, starts_at: %DateTime{}, duration_minutes: d, status: :available})
       when is_binary(id) and id != "" and is_binary(pid) and pid != "" and
              is_integer(d) and d > 0,
       do: true

  defp valid_slot?(_), do: false

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end
```
