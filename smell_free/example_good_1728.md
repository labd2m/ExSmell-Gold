```elixir
defmodule Search.SuggestionEngine do
  @moduledoc """
  GenServer providing low-latency autocomplete suggestions via an in-memory prefix index.

  The index is built from a term corpus at startup and can be incrementally
  updated at runtime. All suggestion lookups are served without I/O.
  """

  use GenServer

  alias Search.SuggestionEngine.{PrefixIndex, SuggestionResult}

  @max_suggestions 10

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Returns up to `limit` suggestions matching the given prefix.
  """
  @spec suggest(String.t(), keyword()) :: [SuggestionResult.t()]
  def suggest(prefix, opts \\ []) when is_binary(prefix) do
    limit = Keyword.get(opts, :limit, @max_suggestions)
    GenServer.call(__MODULE__, {:suggest, prefix, limit})
  end

  @doc """
  Adds a term to the index with an optional weight for ranking.
  """
  @spec index_term(String.t(), non_neg_integer()) :: :ok
  def index_term(term, weight \\ 0) when is_binary(term) and is_integer(weight) and weight >= 0 do
    GenServer.cast(__MODULE__, {:index, term, weight})
  end

  @doc """
  Removes a term from the index.
  """
  @spec remove_term(String.t()) :: :ok
  def remove_term(term) when is_binary(term) do
    GenServer.cast(__MODULE__, {:remove, term})
  end

  @doc """
  Replaces the current index with suggestions built from a new corpus list.
  """
  @spec rebuild([{String.t(), non_neg_integer()}]) :: :ok
  def rebuild(corpus) when is_list(corpus) do
    GenServer.cast(__MODULE__, {:rebuild, corpus})
  end

  @impl GenServer
  def init(opts) do
    corpus = Keyword.get(opts, :corpus, [])
    index = PrefixIndex.build(corpus)
    {:ok, %{index: index}}
  end

  @impl GenServer
  def handle_call({:suggest, prefix, limit}, _from, %{index: index} = state) do
    normalized = String.downcase(prefix)
    results = PrefixIndex.lookup(index, normalized, limit)
    {:reply, results, state}
  end

  @impl GenServer
  def handle_cast({:index, term, weight}, %{index: index} = state) do
    updated = PrefixIndex.insert(index, String.downcase(term), weight)
    {:noreply, %{state | index: updated}}
  end

  def handle_cast({:remove, term}, %{index: index} = state) do
    updated = PrefixIndex.delete(index, String.downcase(term))
    {:noreply, %{state | index: updated}}
  end

  def handle_cast({:rebuild, corpus}, state) do
    {:noreply, %{state | index: PrefixIndex.build(corpus)}}
  end
end

defmodule Search.SuggestionEngine.PrefixIndex do
  @moduledoc "Flat map-based prefix index keyed by term for fast prefix scans."

  alias Search.SuggestionEngine.SuggestionResult

  @type entry :: {String.t(), non_neg_integer()}
  @type t :: %{String.t() => non_neg_integer()}

  @spec build([{String.t(), non_neg_integer()} | String.t()]) :: t()
  def build(corpus) when is_list(corpus) do
    Map.new(corpus, fn
      {term, weight} when is_binary(term) and is_integer(weight) -> {String.downcase(term), weight}
      term when is_binary(term) -> {String.downcase(term), 0}
    end)
  end

  @spec insert(t(), String.t(), non_neg_integer()) :: t()
  def insert(index, term, weight), do: Map.put(index, term, weight)

  @spec delete(t(), String.t()) :: t()
  def delete(index, term), do: Map.delete(index, term)

  @spec lookup(t(), String.t(), pos_integer()) :: [SuggestionResult.t()]
  def lookup(index, prefix, limit) when is_binary(prefix) and is_integer(limit) and limit > 0 do
    index
    |> Enum.filter(fn {term, _weight} -> String.starts_with?(term, prefix) end)
    |> Enum.sort_by(fn {_term, weight} -> weight end, :desc)
    |> Enum.take(limit)
    |> Enum.map(fn {term, weight} -> SuggestionResult.new(term, weight) end)
  end
end

defmodule Search.SuggestionEngine.SuggestionResult do
  @moduledoc "Value object representing a single autocomplete suggestion."

  @enforce_keys [:term, :weight]
  defstruct [:term, :weight]

  @type t :: %__MODULE__{
          term: String.t(),
          weight: non_neg_integer()
        }

  @spec new(String.t(), non_neg_integer()) :: t()
  def new(term, weight) when is_binary(term) and is_integer(weight) do
    %__MODULE__{term: term, weight: weight}
  end
end
```
