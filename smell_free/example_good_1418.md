```elixir
defmodule Infrastructure.Secrets.RotationScheduler do
  @moduledoc """
  Schedules and tracks automatic secret rotation for registered credentials.
  Each credential has an individual rotation interval; the scheduler triggers
  rotation jobs via a pluggable rotator adapter when intervals elapse.
  """

  use GenServer

  @tick_interval_ms 60_000

  @type credential_id :: String.t()
  @type rotation_status :: :ok | :failed
  @type credential_record :: %{
          id: credential_id(),
          name: String.t(),
          rotation_interval_seconds: pos_integer(),
          last_rotated_at: DateTime.t() | nil,
          last_rotation_status: rotation_status() | nil,
          rotation_count: non_neg_integer()
        }
  @type state :: %{
          credentials: %{credential_id() => credential_record()},
          rotator: module()
        }

  @doc """
  Starts the RotationScheduler linked to the calling process.

  ## Options
    - `:rotator` - module implementing `rotate/1` (required)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers a credential for automatic rotation.
  Returns `{:error, :already_registered}` if the ID already exists.
  """
  @spec register(credential_id(), String.t(), pos_integer()) ::
          :ok | {:error, :already_registered | String.t()}
  def register(credential_id, name, rotation_interval_seconds)
      when is_binary(credential_id) and is_binary(name) and
             is_integer(rotation_interval_seconds) and rotation_interval_seconds > 0 do
    GenServer.call(__MODULE__, {:register, credential_id, name, rotation_interval_seconds})
  end

  def register(_id, _name, _interval) do
    {:error, "credential_id and name must be strings; rotation_interval_seconds a positive integer"}
  end

  @doc """
  Triggers an immediate out-of-schedule rotation for `credential_id`.
  """
  @spec rotate_now(credential_id()) :: {:ok, rotation_status()} | {:error, :not_found}
  def rotate_now(credential_id) when is_binary(credential_id) do
    GenServer.call(__MODULE__, {:rotate_now, credential_id})
  end

  @doc """
  Deregisters a credential from automatic rotation.
  """
  @spec deregister(credential_id()) :: :ok
  def deregister(credential_id) when is_binary(credential_id) do
    GenServer.cast(__MODULE__, {:deregister, credential_id})
  end

  @doc """
  Returns the current record for `credential_id`.
  """
  @spec fetch(credential_id()) :: {:ok, credential_record()} | {:error, :not_found}
  def fetch(credential_id) when is_binary(credential_id) do
    GenServer.call(__MODULE__, {:fetch, credential_id})
  end

  @impl GenServer
  def init(opts) do
    rotator = Keyword.fetch!(opts, :rotator)
    schedule_tick()
    {:ok, %{credentials: %{}, rotator: rotator}}
  end

  @impl GenServer
  def handle_call({:register, id, name, interval}, _from, state) do
    if Map.has_key?(state.credentials, id) do
      {:reply, {:error, :already_registered}, state}
    else
      record = %{
        id: id,
        name: name,
        rotation_interval_seconds: interval,
        last_rotated_at: nil,
        last_rotation_status: nil,
        rotation_count: 0
      }

      {:reply, :ok, %{state | credentials: Map.put(state.credentials, id, record)}}
    end
  end

  @impl GenServer
  def handle_call({:rotate_now, credential_id}, _from, state) do
    case Map.fetch(state.credentials, credential_id) do
      :error ->
        {:reply, {:error, :not_found}, state}

      {:ok, record} ->
        {status, updated_record} = perform_rotation(record, state.rotator)
        new_state = %{state | credentials: Map.put(state.credentials, credential_id, updated_record)}
        {:reply, {:ok, status}, new_state}
    end
  end

  @impl GenServer
  def handle_call({:fetch, credential_id}, _from, state) do
    case Map.fetch(state.credentials, credential_id) do
      {:ok, record} -> {:reply, {:ok, record}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  @impl GenServer
  def handle_cast({:deregister, credential_id}, state) do
    {:noreply, %{state | credentials: Map.delete(state.credentials, credential_id)}}
  end

  @impl GenServer
  def handle_info(:tick, state) do
    now = DateTime.utc_now()

    updated_credentials =
      Enum.reduce(state.credentials, state.credentials, fn {id, record}, acc ->
        if rotation_due?(record, now) do
          {_status, updated} = perform_rotation(record, state.rotator)
          Map.put(acc, id, updated)
        else
          acc
        end
      end)

    schedule_tick()
    {:noreply, %{state | credentials: updated_credentials}}
  end

  defp rotation_due?(%{last_rotated_at: nil}, _now), do: true

  defp rotation_due?(%{last_rotated_at: last, rotation_interval_seconds: interval}, now) do
    DateTime.diff(now, last, :second) >= interval
  end

  defp perform_rotation(record, rotator) do
    status =
      case rotator.rotate(record.id) do
        :ok -> :ok
        {:error, _} -> :failed
      end

    updated = %{
      record
      | last_rotated_at: DateTime.utc_now(),
        last_rotation_status: status,
        rotation_count: record.rotation_count + 1
    }

    {status, updated}
  end

  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_interval_ms)
end
```
