```elixir
defmodule Audit.Entry do
  @moduledoc false

  @type t :: %__MODULE__{
          actor_id: String.t(),
          action: String.t(),
          resource_type: String.t(),
          resource_id: String.t() | nil,
          metadata: map(),
          occurred_at: DateTime.t()
        }

  defstruct [:actor_id, :action, :resource_type, :resource_id, :metadata, :occurred_at]

  @spec new(String.t(), String.t(), String.t(), String.t() | nil, map()) :: t()
  def new(actor_id, action, resource_type, resource_id \\ nil, metadata \\ %{}) do
    %__MODULE__{
      actor_id: actor_id,
      action: action,
      resource_type: resource_type,
      resource_id: resource_id,
      metadata: metadata,
      occurred_at: DateTime.utc_now()
    }
  end
end

defmodule Audit.Store do
  @moduledoc false

  alias Audit.Entry

  @spec persist([Entry.t()]) :: :ok | {:error, term()}
  def persist(entries) when is_list(entries) do
    rows =
      Enum.map(entries, fn e ->
        %{
          actor_id: e.actor_id,
          action: e.action,
          resource_type: e.resource_type,
          resource_id: e.resource_id,
          metadata: e.metadata,
          occurred_at: e.occurred_at
        }
      end)

    Audit.Repo.insert_all("audit_log", rows)
    :ok
  rescue
    error -> {:error, error}
  end
end

defmodule Audit.Logger do
  @moduledoc """
  Collects and bulk-flushes structured audit entries.

  Entries are accumulated in an in-memory buffer and written to persistent
  storage when either the buffer reaches `buffer_limit` or the
  `flush_interval_ms` timer fires, whichever comes first.
  This approach reduces write amplification on high-throughput workloads
  while ensuring entries are never held longer than the flush window.
  """

  use GenServer

  alias Audit.{Entry, Store}

  @type opts :: [
          name: atom(),
          flush_interval_ms: pos_integer(),
          buffer_limit: pos_integer()
        ]

  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec record(atom(), String.t(), String.t(), String.t(), String.t() | nil, map()) :: :ok
  def record(server \\ __MODULE__, actor_id, action, resource_type, resource_id, metadata)
      when is_binary(actor_id) and is_binary(action) and is_binary(resource_type) do
    entry = Entry.new(actor_id, action, resource_type, resource_id, metadata)
    GenServer.cast(server, {:record, entry})
  end

  @impl GenServer
  def init(opts) do
    interval = Keyword.get(opts, :flush_interval_ms, 5_000)
    limit = Keyword.get(opts, :buffer_limit, 200)
    schedule_flush(interval)
    {:ok, %{buffer: [], flush_interval_ms: interval, buffer_limit: limit}}
  end

  @impl GenServer
  def handle_cast({:record, entry}, state) do
    updated = [entry | state.buffer]

    if length(updated) >= state.buffer_limit do
      flush(updated)
      {:noreply, %{state | buffer: []}}
    else
      {:noreply, %{state | buffer: updated}}
    end
  end

  @impl GenServer
  def handle_info(:flush, %{buffer: []} = state) do
    schedule_flush(state.flush_interval_ms)
    {:noreply, state}
  end

  def handle_info(:flush, state) do
    flush(state.buffer)
    schedule_flush(state.flush_interval_ms)
    {:noreply, %{state | buffer: []}}
  end

  defp flush(entries) do
    entries |> Enum.reverse() |> Store.persist()
  end

  defp schedule_flush(interval) do
    Process.send_after(self(), :flush, interval)
  end
end
```
