```elixir
defmodule Platform.ChangelogWriter do
  @moduledoc """
  Appends structured changelog entries for domain model mutations. Each
  entry records the actor, action, before/after snapshots, and a
  correlation ID that links entries from the same logical operation.
  Entries are written asynchronously via a supervised cast so the hot
  path is never slowed by changelog persistence.
  """

  use GenServer

  require Logger

  alias MyApp.Repo
  alias Platform.ChangelogEntry

  @type actor_id :: String.t()
  @type resource_type :: String.t()
  @type resource_id :: String.t()
  @type action :: String.t()
  @type snapshot :: map() | nil

  @type entry_params :: %{
          correlation_id: String.t(),
          actor_id: actor_id(),
          action: action(),
          resource_type: resource_type(),
          resource_id: resource_id(),
          before_snapshot: snapshot(),
          after_snapshot: snapshot(),
          metadata: map()
        }

  @flush_interval_ms :timer.seconds(5)
  @max_buffer 500

  @doc "Starts the changelog writer registered under its module name."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Appends an entry to the write buffer asynchronously."
  @spec append(entry_params()) :: :ok
  def append(%{correlation_id: _, actor_id: _, action: _, resource_type: _, resource_id: _} = params) do
    GenServer.cast(__MODULE__, {:append, params})
  end

  @doc "Generates a new correlation ID suitable for linking related entries."
  @spec new_correlation_id() :: String.t()
  def new_correlation_id do
    :crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower)
  end

  @doc "Forces an immediate flush of the write buffer to the database."
  @spec flush() :: :ok
  def flush, do: GenServer.call(__MODULE__, :flush)

  @impl GenServer
  def init(opts) do
    interval = Keyword.get(opts, :flush_interval_ms, @flush_interval_ms)
    Process.send_after(self(), :flush, interval)
    {:ok, %{buffer: [], flush_interval: interval}}
  end

  @impl GenServer
  def handle_cast({:append, params}, %{buffer: buffer} = state) do
    new_buffer = [params | buffer]

    if length(new_buffer) >= @max_buffer do
      write_buffer(new_buffer)
      {:noreply, %{state | buffer: []}}
    else
      {:noreply, %{state | buffer: new_buffer}}
    end
  end

  @impl GenServer
  def handle_call(:flush, _from, state) do
    write_buffer(state.buffer)
    {:reply, :ok, %{state | buffer: []}}
  end

  @impl GenServer
  def handle_info(:flush, %{buffer: [], flush_interval: interval} = state) do
    Process.send_after(self(), :flush, interval)
    {:noreply, state}
  end

  def handle_info(:flush, %{flush_interval: interval} = state) do
    write_buffer(state.buffer)
    Process.send_after(self(), :flush, interval)
    {:noreply, %{state | buffer: []}}
  end

  defp write_buffer(entries) when entries == [], do: :ok

  defp write_buffer(entries) do
    now = DateTime.utc_now()

    rows =
      Enum.map(entries, fn e ->
        %{
          correlation_id: e.correlation_id,
          actor_id: e.actor_id,
          action: e.action,
          resource_type: e.resource_type,
          resource_id: e.resource_id,
          before_snapshot: e[:before_snapshot],
          after_snapshot: e[:after_snapshot],
          metadata: e[:metadata] || %{},
          inserted_at: now
        }
      end)

    Repo.insert_all(ChangelogEntry, rows)
    Logger.debug("[ChangelogWriter] Flushed #{length(rows)} changelog entry(ies)")
  rescue
    e -> Logger.error("[ChangelogWriter] Flush failed: #{Exception.message(e)}")
  end
end
```
