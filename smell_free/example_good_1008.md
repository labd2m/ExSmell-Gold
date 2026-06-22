```elixir
defmodule MyApp.Commerce.StockReservationSupervisor do
  @moduledoc """
  A `DynamicSupervisor` that hosts transient stock reservation processes.
  When a user begins checkout a short-lived reservation process holds
  their cart items for a configurable duration, preventing overselling
  during concurrent checkouts. When the user completes or abandons
  checkout, or when the reservation expires, the process exits and
  stock is automatically released.
  """

  use DynamicSupervisor

  @reservation_ttl_ms 10 * 60 * 1_000

  @doc "Starts the reservation supervisor."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Starts a reservation for `session_id` covering the given `items`.
  Returns `{:ok, pid}` or `{:error, :already_reserved}` when an active
  reservation exists for the session.
  """
  @spec reserve(String.t(), [map()]) :: {:ok, pid()} | {:error, :already_reserved} | {:error, term()}
  def reserve(session_id, items) when is_binary(session_id) and is_list(items) do
    case Registry.lookup(MyApp.Commerce.ReservationRegistry, session_id) do
      [{_pid, _}] ->
        {:error, :already_reserved}

      [] ->
        DynamicSupervisor.start_child(__MODULE__, {
          MyApp.Commerce.ReservationProcess,
          session_id: session_id,
          items: items,
          ttl_ms: @reservation_ttl_ms
        })
    end
  end

  @doc "Extends an existing reservation's TTL."
  @spec extend(String.t()) :: :ok | {:error, :not_found}
  def extend(session_id) when is_binary(session_id) do
    case Registry.lookup(MyApp.Commerce.ReservationRegistry, session_id) do
      [{pid, _}] ->
        GenServer.cast(pid, :extend)

      [] ->
        {:error, :not_found}
    end
  end

  @doc "Releases a reservation without completing checkout."
  @spec release(String.t()) :: :ok
  def release(session_id) when is_binary(session_id) do
    case Registry.lookup(MyApp.Commerce.ReservationRegistry, session_id) do
      [{pid, _}] -> GenServer.stop(pid, :normal)
      [] -> :ok
    end
  end

  @doc "Returns the reserved items for `session_id`, or `nil`."
  @spec reserved_items(String.t()) :: [map()] | nil
  def reserved_items(session_id) when is_binary(session_id) do
    case Registry.lookup(MyApp.Commerce.ReservationRegistry, session_id) do
      [{pid, _}] -> GenServer.call(pid, :items)
      [] -> nil
    end
  end

  @impl DynamicSupervisor
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
```
