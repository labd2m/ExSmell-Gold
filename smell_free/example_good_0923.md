```elixir
defmodule Platform.CdcConsumer do
  @moduledoc """
  A GenServer that consumes PostgreSQL logical replication events via the
  `postgrex_wal` or Epgsql replication protocol, translating row-level changes
  (insert, update, delete) into typed domain events for downstream consumers.

  Each captured change is dispatched to a configurable handler and published
  to PubSub so that caches, search indexes, and read models can react to
  database mutations without polling.
  """

  use GenServer

  require Logger

  alias Phoenix.PubSub

  @type operation :: :insert | :update | :delete
  @type change_event :: %{
          table: String.t(),
          operation: operation(),
          schema: String.t(),
          old_row: map() | nil,
          new_row: map() | nil,
          lsn: String.t()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Returns the last processed LSN position."
  @spec last_lsn(GenServer.server()) :: String.t() | nil
  def last_lsn(server \\ __MODULE__), do: GenServer.call(server, :last_lsn)

  @impl GenServer
  def init(opts) do
    tables = Keyword.get(opts, :tables, [])
    pubsub = Keyword.get(opts, :pubsub, Platform.PubSub)
    handler = Keyword.get(opts, :handler)
    slot_name = Keyword.fetch!(opts, :slot_name)

    state = %{
      tables: MapSet.new(tables),
      pubsub: pubsub,
      handler: handler,
      slot_name: slot_name,
      last_lsn: nil,
      processed_count: 0
    }

    send(self(), :connect)
    {:ok, state}
  end

  @impl GenServer
  def handle_call(:last_lsn, _from, state) do
    {:reply, state.last_lsn, state}
  end

  @impl GenServer
  def handle_info(:connect, state) do
    Logger.info("[CdcConsumer] Connecting to replication slot", slot: state.slot_name)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:wal_event, raw_event}, state) do
    case parse_wal_event(raw_event) do
      {:ok, change} ->
        new_state = process_change(state, change)
        {:noreply, new_state}

      {:error, reason} ->
        Logger.warning("[CdcConsumer] Failed to parse WAL event", reason: inspect(reason))
        {:noreply, state}
    end
  end

  defp process_change(%{tables: tables} = state, %{table: table} = change) do
    if MapSet.size(tables) == 0 or table in tables do
      dispatch(state, change)
      %{state | last_lsn: change.lsn, processed_count: state.processed_count + 1}
    else
      state
    end
  end

  defp dispatch(%{handler: handler, pubsub: pubsub}, change) do
    topic = "cdc:#{change.schema}.#{change.table}"
    PubSub.broadcast(pubsub, topic, {:cdc_change, change})

    if handler do
      Task.start(fn -> safe_call_handler(handler, change) end)
    end
  end

  defp safe_call_handler(handler, change) do
    handler.(change)
  rescue
    error ->
      Logger.error("[CdcConsumer] Handler raised",
        table: change.table,
        operation: change.operation,
        error: inspect(error)
      )
  end

  defp parse_wal_event(%{relation: {schema, table}, action: action} = event) do
    operation = case action do
      :insert -> :insert
      :update -> :update
      :delete -> :delete
      _ -> :unknown
    end

    change = %{
      table: table,
      schema: schema,
      operation: operation,
      old_row: Map.get(event, :old_data),
      new_row: Map.get(event, :new_data),
      lsn: Map.get(event, :lsn, "0/0")
    }

    {:ok, change}
  end

  defp parse_wal_event(unknown) do
    {:error, {:unrecognized_event_format, unknown}}
  end
end
```
