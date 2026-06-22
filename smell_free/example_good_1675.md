```elixir
defmodule Search.AutocompleteEngine do
  @moduledoc """
  An ETS-backed autocomplete engine that indexes terms from a corpus
  and returns ranked prefix-match suggestions. The index is built
  incrementally and served entirely from memory for sub-millisecond lookups.
  """

  use GenServer

  @table :autocomplete_index
  @max_suggestions 10

  @type term_entry :: %{term: String.t(), score: float(), metadata: map()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec suggest(String.t(), keyword()) :: [term_entry()]
  def suggest(prefix, opts \\ []) when is_binary(prefix) do
    limit = Keyword.get(opts, :limit, @max_suggestions)
    normalized = String.downcase(String.trim(prefix))

    if byte_size(normalized) == 0 do
      []
    else
      lookup(normalized, limit)
    end
  end

  @spec index_term(String.t(), float(), map()) :: :ok
  def index_term(term, score \\ 1.0, metadata \\ %{}) when is_binary(term) do
    GenServer.cast(__MODULE__, {:index, term, score, metadata})
  end

  @spec index_batch([%{term: String.t(), score: float(), metadata: map()}]) :: :ok
  def index_batch(entries) when is_list(entries) do
    GenServer.cast(__MODULE__, {:index_batch, entries})
  end

  @spec remove_term(String.t()) :: :ok
  def remove_term(term) when is_binary(term) do
    GenServer.cast(__MODULE__, {:remove, term})
  end

  @spec term_count() :: non_neg_integer()
  def term_count do
    :ets.info(@table, :size)
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :ordered_set, :public, read_concurrency: true])
    {:ok, %{}}
  end

  @impl GenServer
  def handle_cast({:index, term, score, metadata}, state) do
    insert_term(term, score, metadata)
    {:noreply, state}
  end

  def handle_cast({:index_batch, entries}, state) do
    Enum.each(entries, fn entry ->
      insert_term(entry.term, Map.get(entry, :score, 1.0), Map.get(entry, :metadata, %{}))
    end)

    {:noreply, state}
  end

  def handle_cast({:remove, term}, state) do
    normalized = String.downcase(term)
    :ets.delete(@table, normalized)
    {:noreply, state}
  end

  @spec insert_term(String.t(), float(), map()) :: true
  defp insert_term(term, score, metadata) do
    normalized = String.downcase(String.trim(term))
    :ets.insert(@table, {normalized, score, metadata})
  end

  @spec lookup(String.t(), pos_integer()) :: [term_entry()]
  defp lookup(prefix, limit) do
    match_spec = [
      {{:"$1", :"$2", :"$3"},
       [{:>=, :"$1", prefix}, {:<, :"$1", next_prefix(prefix)}],
       [{{:"$1", :"$2", :"$3"}}]}
    ]

    @table
    |> :ets.select(match_spec)
    |> Enum.sort_by(fn {_term, score, _meta} -> -score end)
    |> Enum.take(limit)
    |> Enum.map(fn {term, score, metadata} ->
      %{term: term, score: score, metadata: metadata}
    end)
  end

  @spec next_prefix(String.t()) :: String.t()
  defp next_prefix(prefix) do
    case String.reverse(prefix) do
      "" ->
        ""

      reversed ->
        last_char = String.first(reversed)
        rest = String.slice(reversed, 1..-1//1)
        incremented = <<:binary.first(last_char) + 1>>
        String.reverse(rest <> incremented)
    end
  end
end
```
