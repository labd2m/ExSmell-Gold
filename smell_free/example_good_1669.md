```elixir
defmodule Leases.Lease do
  @moduledoc """
  A time-bounded exclusive lease on a named resource.
  Leases are issued with a holder identity and a configurable TTL.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          resource: String.t(),
          holder_id: String.t(),
          granted_at: DateTime.t(),
          expires_at: DateTime.t()
        }

  defstruct [:id, :resource, :holder_id, :granted_at, :expires_at]

  @spec active?(%__MODULE__{}) :: boolean()
  def active?(%__MODULE__{expires_at: exp}) do
    DateTime.compare(DateTime.utc_now(), exp) == :lt
  end

  @spec held_by?(%__MODULE__{}, String.t()) :: boolean()
  def held_by?(%__MODULE__{holder_id: holder}, candidate) when is_binary(candidate) do
    holder == candidate
  end
end

defmodule Leases.Manager do
  use GenServer

  alias Leases.Lease

  @moduledoc """
  Manages exclusive time-bounded leases on named resources.
  Expired leases are evicted lazily on access and eagerly via a sweep timer.
  Lease holders must renew before expiry to maintain exclusivity.
  """

  @sweep_interval_ms 10_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put(opts, :name, __MODULE__))
  end

  @spec acquire(String.t(), String.t(), pos_integer()) ::
          {:ok, Lease.t()} | {:error, :already_leased}
  def acquire(resource, holder_id, ttl_seconds)
      when is_binary(resource) and is_binary(holder_id) and is_integer(ttl_seconds) do
    GenServer.call(__MODULE__, {:acquire, resource, holder_id, ttl_seconds})
  end

  @spec renew(String.t(), String.t(), pos_integer()) ::
          {:ok, Lease.t()} | {:error, :lease_not_held | :lease_expired}
  def renew(resource, holder_id, ttl_seconds) when is_binary(resource) and is_binary(holder_id) do
    GenServer.call(__MODULE__, {:renew, resource, holder_id, ttl_seconds})
  end

  @spec release(String.t(), String.t()) :: :ok | {:error, :lease_not_held}
  def release(resource, holder_id) when is_binary(resource) and is_binary(holder_id) do
    GenServer.call(__MODULE__, {:release, resource, holder_id})
  end

  @spec current_lease(String.t()) :: {:ok, Lease.t()} | {:error, :not_leased | :expired}
  def current_lease(resource) when is_binary(resource) do
    GenServer.call(__MODULE__, {:current, resource})
  end

  @impl GenServer
  def init(:ok) do
    schedule_sweep()
    {:ok, %{leases: %{}}}
  end

  @impl GenServer
  def handle_call({:acquire, resource, holder_id, ttl}, _from, state) do
    case Map.fetch(state.leases, resource) do
      {:ok, existing} when Lease.active?(existing) ->
        {:reply, {:error, :already_leased}, state}

      _ ->
        lease = build_lease(resource, holder_id, ttl)
        {:reply, {:ok, lease}, put_in(state.leases[resource], lease)}
    end
  end

  def handle_call({:renew, resource, holder_id, ttl}, _from, state) do
    case Map.fetch(state.leases, resource) do
      {:ok, lease} when not Lease.active?(lease) ->
        {:reply, {:error, :lease_expired}, state}

      {:ok, lease} when not Lease.held_by?(lease, holder_id) ->
        {:reply, {:error, :lease_not_held}, state}

      {:ok, _lease} ->
        renewed = build_lease(resource, holder_id, ttl)
        {:reply, {:ok, renewed}, put_in(state.leases[resource], renewed)}

      :error ->
        {:reply, {:error, :lease_not_held}, state}
    end
  end

  def handle_call({:release, resource, holder_id}, _from, state) do
    case Map.fetch(state.leases, resource) do
      {:ok, lease} when Lease.held_by?(lease, holder_id) ->
        {:reply, :ok, %{state | leases: Map.delete(state.leases, resource)}}

      {:ok, _} ->
        {:reply, {:error, :lease_not_held}, state}

      :error ->
        {:reply, {:error, :lease_not_held}, state}
    end
  end

  def handle_call({:current, resource}, _from, state) do
    case Map.fetch(state.leases, resource) do
      {:ok, lease} when Lease.active?(lease) -> {:reply, {:ok, lease}, state}
      {:ok, _expired} -> {:reply, {:error, :expired}, Map.delete(state.leases, resource) |> then(&%{state | leases: &1})}
      :error -> {:reply, {:error, :not_leased}, state}
    end
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    alive = Enum.reject(state.leases, fn {_, lease} -> not Lease.active?(lease) end) |> Map.new()
    schedule_sweep()
    {:noreply, %{state | leases: alive}}
  end

  defp build_lease(resource, holder_id, ttl) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    %Lease{
      id: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower),
      resource: resource,
      holder_id: holder_id,
      granted_at: now,
      expires_at: DateTime.add(now, ttl, :second)
    }
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end
```
