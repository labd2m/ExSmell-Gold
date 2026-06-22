```elixir
defmodule Journal.Entry do
  @moduledoc false

  @type t :: %__MODULE__{
          version: pos_integer(),
          actor_id: String.t() | nil,
          event: atom(),
          payload: map(),
          occurred_at: integer()
        }

  defstruct [:version, :actor_id, :event, :payload, :occurred_at]
end

defmodule Journal.Store do
  @moduledoc """
  An append-only, per-entity change journal backed by ETS.

  Each entity has an isolated list of `Entry` structs ordered by version.
  Entries are immutable once written; `append/4` is the only mutation.
  `replay/3` streams all entries for an entity from a given version,
  enabling read-model rebuild and audit trail queries without loading the
  full history into memory when combined with `Stream.resource`.
  """

  use GenServer

  alias Journal.Entry

  @table __MODULE__

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec append(String.t(), atom(), map(), String.t() | nil) ::
          {:ok, Entry.t()} | {:error, term()}
  def append(entity_id, event, payload, actor_id \\ nil)
      when is_binary(entity_id) and is_atom(event) and is_map(payload) do
    GenServer.call(__MODULE__, {:append, entity_id, event, payload, actor_id})
  end

  @spec entries(String.t(), pos_integer()) :: [Entry.t()]
  def entries(entity_id, from_version \\ 1) when is_binary(entity_id) do
    case :ets.lookup(@table, entity_id) do
      [{^entity_id, all}] -> Enum.drop_while(all, &(&1.version < from_version))
      [] -> []
    end
  end

  @spec latest_version(String.t()) :: non_neg_integer()
  def latest_version(entity_id) when is_binary(entity_id) do
    case :ets.lookup(@table, entity_id) do
      [{^entity_id, [latest | _]}] -> latest.version
      _ -> 0
    end
  end

  @spec replay(String.t(), pos_integer(), (Entry.t() -> :ok)) :: :ok
  def replay(entity_id, from_version \\ 1, handler_fn)
      when is_binary(entity_id) and is_function(handler_fn, 1) do
    entity_id
    |> entries(from_version)
    |> Enum.each(handler_fn)
  end

  @spec entity_count() :: non_neg_integer()
  def entity_count, do: :ets.info(@table, :size)

  @spec purge(String.t(), pos_integer()) :: {:ok, non_neg_integer()}
  def purge(entity_id, keep_from_version) when is_binary(entity_id) do
    GenServer.call(__MODULE__, {:purge, entity_id, keep_from_version})
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:append, entity_id, event, payload, actor_id}, _from, state) do
    existing = case :ets.lookup(@table, entity_id) do
      [{^entity_id, entries}] -> entries
      [] -> []
    end

    next_version = case existing do
      [latest | _] -> latest.version + 1
      [] -> 1
    end

    entry = %Entry{
      version: next_version,
      actor_id: actor_id,
      event: event,
      payload: payload,
      occurred_at: System.system_time(:millisecond)
    }

    :ets.insert(@table, {entity_id, [entry | existing]})
    {:reply, {:ok, entry}, state}
  end

  def handle_call({:purge, entity_id, keep_from_version}, _from, state) do
    case :ets.lookup(@table, entity_id) do
      [{^entity_id, entries}] ->
        {kept, removed} = Enum.split_with(entries, &(&1.version >= keep_from_version))
        :ets.insert(@table, {entity_id, kept})
        {:reply, {:ok, length(removed)}, state}

      [] ->
        {:reply, {:ok, 0}, state}
    end
  end
end
```
