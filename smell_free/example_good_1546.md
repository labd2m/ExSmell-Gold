```elixir
defmodule Audit.TrailRecorder do
  @moduledoc """
  Asynchronous audit trail recorder for tracking sensitive resource mutations.

  Buffers audit entries in-process and flushes them in batches to the
  database. Designed to be placed under a supervision tree with a
  configurable flush interval and maximum buffer size.
  """

  use GenServer

  require Logger

  alias Audit.{AuditEntry, Repo}

  @default_flush_interval_ms 5_000
  @default_max_buffer_size 500

  @type audit_params :: %{
          actor_id: String.t(),
          action: atom(),
          resource_type: String.t(),
          resource_id: String.t(),
          changes: map()
        }

  @doc """
  Starts the audit trail recorder as a named linked process.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Enqueues an audit entry for async batch persistence.

  Returns `:ok` immediately. If the buffer exceeds its capacity,
  a synchronous flush is triggered before enqueuing.
  """
  @spec record(audit_params()) :: :ok
  def record(%{actor_id: _, action: _, resource_type: _, resource_id: _} = params) do
    GenServer.cast(__MODULE__, {:record, params})
  end

  @doc """
  Forces an immediate flush of all buffered audit entries to the database.
  """
  @spec flush() :: :ok
  def flush do
    GenServer.call(__MODULE__, :flush)
  end

  @impl GenServer
  def init(opts) do
    flush_interval = Keyword.get(opts, :flush_interval_ms, @default_flush_interval_ms)
    max_buffer = Keyword.get(opts, :max_buffer_size, @default_max_buffer_size)
    schedule_flush(flush_interval)

    {:ok,
     %{
       buffer: [],
       buffer_count: 0,
       flush_interval_ms: flush_interval,
       max_buffer_size: max_buffer
     }}
  end

  @impl GenServer
  def handle_cast({:record, params}, state) do
    enriched = enrich_entry(params)
    new_buffer = [enriched | state.buffer]
    new_count = state.buffer_count + 1

    if new_count >= state.max_buffer_size do
      flush_buffer(new_buffer)
      {:noreply, %{state | buffer: [], buffer_count: 0}}
    else
      {:noreply, %{state | buffer: new_buffer, buffer_count: new_count}}
    end
  end

  @impl GenServer
  def handle_call(:flush, _from, %{buffer: buffer} = state) do
    flush_buffer(buffer)
    {:reply, :ok, %{state | buffer: [], buffer_count: 0}}
  end

  @impl GenServer
  def handle_info(:scheduled_flush, state) do
    unless state.buffer == [], do: flush_buffer(state.buffer)
    schedule_flush(state.flush_interval_ms)
    {:noreply, %{state | buffer: [], buffer_count: 0}}
  end

  defp enrich_entry(params) do
    Map.merge(params, %{
      occurred_at: DateTime.utc_now(),
      node: node()
    })
  end

  defp flush_buffer([]), do: :ok

  defp flush_buffer(entries) do
    changesets =
      Enum.map(entries, fn entry ->
        AuditEntry.changeset(%AuditEntry{}, entry)
      end)

    valid = Enum.filter(changesets, & &1.valid?)
    invalid_count = length(changesets) - length(valid)

    if invalid_count > 0 do
      Logger.warning("[AuditTrail] Dropped #{invalid_count} invalid audit entries during flush")
    end

    Enum.each(valid, fn cs ->
      case Repo.insert(cs) do
        {:ok, _} -> :ok
        {:error, err} -> Logger.error("[AuditTrail] Failed to persist entry: #{inspect(err)}")
      end
    end)
  end

  defp schedule_flush(interval_ms) do
    Process.send_after(self(), :scheduled_flush, interval_ms)
  end
end
```
