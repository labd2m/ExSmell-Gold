```elixir
defmodule MyApp.Search.TypeaheadIndex do
  @moduledoc """
  Maintains an in-process trigram index for instant typeahead suggestions.
  Each indexed term is broken into overlapping trigrams stored in ETS for
  fast prefix and fuzzy lookups without a database round-trip. The index
  is rebuilt from the database on startup and refreshed on a configurable
  interval so that newly added terms appear within one refresh cycle.
  """

  use GenServer

  require Logger

  import Ecto.Query, warn: false

  alias MyApp.Repo

  @table __MODULE__
  @rebuild_interval_ms 5 * 60 * 1_000

  @type entry :: %{id: String.t(), term: String.t(), type: atom(), weight: pos_integer()}

  @doc "Starts the typeahead index."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns up to `limit` suggestions for `prefix`, sorted by weight
  descending.
  """
  @spec suggest(String.t(), pos_integer()) :: [entry()]
  def suggest(prefix, limit \\ 10)
      when is_binary(prefix) and byte_size(prefix) > 0 and is_integer(limit) do
    prefix_lower = String.downcase(prefix)
    trigrams = extract_trigrams(prefix_lower)

    if trigrams == [] do
      []
    else
      trigrams
      |> Enum.flat_map(&:ets.lookup(@table, &1))
      |> Enum.map(fn {_trigram, entry} -> entry end)
      |> Enum.filter(fn e -> String.starts_with?(String.downcase(e.term), prefix_lower) end)
      |> Enum.uniq_by(& &1.id)
      |> Enum.sort_by(& &1.weight, :desc)
      |> Enum.take(limit)
    end
  end

  @doc "Adds or updates a single entry in the index."
  @spec upsert(entry()) :: :ok
  def upsert(entry) when is_map(entry) do
    GenServer.cast(__MODULE__, {:upsert, entry})
  end

  @doc "Removes all entries for `id` from the index."
  @spec remove(String.t()) :: :ok
  def remove(id) when is_binary(id) do
    GenServer.cast(__MODULE__, {:remove, id})
  end

  @impl GenServer
  def init(opts) do
    :ets.new(@table, [:named_table, :public, :bag, read_concurrency: true])
    rebuild()
    schedule_rebuild(Keyword.get(opts, :rebuild_interval_ms, @rebuild_interval_ms))
    {:ok, %{interval_ms: Keyword.get(opts, :rebuild_interval_ms, @rebuild_interval_ms)}}
  end

  @impl GenServer
  def handle_cast({:upsert, entry}, state) do
    remove_entry(entry.id)
    index_entry(entry)
    {:noreply, state}
  end

  @impl GenServer
  def handle_cast({:remove, id}, state) do
    remove_entry(id)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:rebuild, state) do
    rebuild()
    schedule_rebuild(state.interval_ms)
    {:noreply, state}
  end

  @spec rebuild() :: :ok
  defp rebuild do
    entries = load_entries()
    :ets.delete_all_objects(@table)
    Enum.each(entries, &index_entry/1)
    Logger.debug("typeahead_index_rebuilt", entry_count: length(entries))
    :ok
  end

  @spec index_entry(entry()) :: :ok
  defp index_entry(entry) do
    entry.term
    |> String.downcase()
    |> extract_trigrams()
    |> Enum.each(fn trigram ->
      :ets.insert(@table, {trigram, entry})
    end)
  end

  @spec remove_entry(String.t()) :: :ok
  defp remove_entry(id) do
    :ets.select_delete(@table, [{{:_, %{id: id}}, [], [true]}])
    :ok
  end

  @spec extract_trigrams(String.t()) :: [String.t()]
  defp extract_trigrams(term) when byte_size(term) < 2, do: [term]

  defp extract_trigrams(term) do
    chars = String.graphemes(term)
    len = length(chars)

    Enum.map(0..(len - 2), fn i ->
      chars |> Enum.slice(i, 3) |> Enum.join()
    end)
    |> Enum.uniq()
  end

  @spec load_entries() :: [entry()]
  defp load_entries do
    sources = [
      {MyApp.Catalog.Product, :name, :product, :search_score},
      {MyApp.Accounts.User, :name, :user, 1}
    ]

    Enum.flat_map(sources, fn {schema, field, type, weight_field} ->
      schema
      |> select([r], {r.id, field(r, ^field), field(r, ^weight_field)})
      |> Repo.all()
      |> Enum.map(fn {id, term, weight} ->
        %{id: id, term: term || "", type: type, weight: weight || 1}
      end)
      |> Enum.reject(fn e -> e.term == "" end)
    end)
  end

  @spec schedule_rebuild(pos_integer()) :: reference()
  defp schedule_rebuild(interval_ms),
    do: Process.send_after(self(), :rebuild, interval_ms)
end
```
