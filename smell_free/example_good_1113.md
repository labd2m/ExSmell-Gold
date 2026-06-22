```elixir
defmodule Events.Dispatcher do
  @moduledoc """
  Routes domain events to registered handler modules.
  Handlers are registered at startup via configuration rather than at runtime,
  ensuring the routing table is stable and inspectable.

  Each handler module must export a `handle/1` function accepting an event struct.
  """

  use GenServer

  @type event :: struct()
  @type handler :: module()
  @type routing_table :: %{required(module()) => [handler()]}

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Dispatches an event to all handlers registered for its type."
  @spec dispatch(event()) :: :ok
  def dispatch(%_{} = event) do
    GenServer.call(__MODULE__, {:dispatch, event})
  end

  @doc "Returns the current routing table for introspection and testing."
  @spec routing_table() :: routing_table()
  def routing_table do
    GenServer.call(__MODULE__, :routing_table)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    routes = Keyword.fetch!(opts, :routes)
    table = build_routing_table(routes)
    {:ok, %{table: table}}
  end

  @impl GenServer
  def handle_call({:dispatch, event}, _from, state) do
    event_type = event.__struct__
    handlers = Map.get(state.table, event_type, [])
    Enum.each(handlers, fn handler -> invoke_handler(handler, event) end)
    {:reply, :ok, state}
  end

  def handle_call(:routing_table, _from, state) do
    {:reply, state.table, state}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp build_routing_table(routes) do
    Enum.reduce(routes, %{}, fn {event_type, handlers}, acc ->
      Map.update(acc, event_type, handlers, &(&1 ++ handlers))
    end)
  end

  defp invoke_handler(handler, event) do
    try do
      handler.handle(event)
    rescue
      exception ->
        require Logger
        Logger.error("Handler #{inspect(handler)} raised for #{inspect(event.__struct__)}",
          error: Exception.message(exception)
        )
    end
  end
end
```
