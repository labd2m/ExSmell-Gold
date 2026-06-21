```elixir
defmodule MyApp.Search.Suggester do
  @moduledoc """
  Provides real-time search suggestions by querying a trie structure
  populated from the product catalog. The trie is built in memory at
  startup from product names and common search terms, enabling prefix
  lookups that return ranked suggestions in microseconds without a
  database round-trip.

  The trie is rebuilt on a configurable schedule to pick up new catalog
  entries.
  """

  use GenServer

  require Logger

  alias MyApp.Repo
  alias MyApp.Catalog.Product

  import Ecto.Query, warn: false

  @max_suggestions 10
  @rebuild_interval_ms 10 * 60 * 1_000

  @type suggestion :: %{text: String.t(), score: pos_integer()}

  @doc "Starts the suggester and builds the initial trie."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns up to `#{@max_suggestions}` suggestions for `prefix`, sorted
  by descending score.
  """
  @spec suggest(String.t(), pos_integer()) :: [suggestion()]
  def suggest(prefix, limit \\ @max_suggestions)
      when is_binary(prefix) and is_integer(limit) and limit > 0 do
    GenServer.call(__MODULE__, {:suggest, String.downcase(prefix), min(limit, @max_suggestions)})
  end

  @impl GenServer
  def init(opts) do
    trie = build_trie()
    schedule_rebuild(Keyword.get(opts, :rebuild_interval_ms, @rebuild_interval_ms))
    {:ok, %{trie: trie, rebuild_interval_ms: Keyword.get(opts, :rebuild_interval_ms, @rebuild_interval_ms)}}
  end

  @impl GenServer
  def handle_call({:suggest, prefix, limit}, _from, state) do
    results = prefix_lookup(state.trie, prefix, limit)
    {:reply, results, state}
  end

  @impl GenServer
  def handle_info(:rebuild, state) do
    trie = build_trie()
    Logger.info("suggester_trie_rebuilt", entries: map_size(trie))
    schedule_rebuild(state.rebuild_interval_ms)
    {:noreply, %{state | trie: trie}}
  end

  @spec build_trie() :: %{String.t() => pos_integer()}
  defp build_trie do
    Product
    |> where([p], p.active == true)
    |> select([p], {p.name, p.search_score})
    |> Repo.all()
    |> Enum.reduce(%{}, fn {name, score}, acc ->
      name
      |> String.downcase()
      |> build_prefixes()
      |> Enum.reduce(acc, fn prefix, inner_acc ->
        Map.update(inner_acc, prefix, {name, score}, fn {existing_name, existing_score} ->
          if score > existing_score, do: {name, score}, else: {existing_name, existing_score}
        end)
      end)
    end)
  end

  @spec build_prefixes(String.t()) :: [String.t()]
  defp build_prefixes(text) do
    1..String.length(text)
    |> Enum.map(&String.slice(text, 0, &1))
  end

  @spec prefix_lookup(%{String.t() => {String.t(), pos_integer()}}, String.t(), pos_integer()) ::
          [suggestion()]
  defp prefix_lookup(trie, prefix, limit) do
    trie
    |> Enum.filter(fn {key, _} -> String.starts_with?(key, prefix) end)
    |> Enum.map(fn {_, {text, score}} -> {text, score} end)
    |> Enum.uniq_by(&elem(&1, 0))
    |> Enum.sort_by(&elem(&1, 1), :desc)
    |> Enum.take(limit)
    |> Enum.map(fn {text, score} -> %{text: text, score: score} end)
  end

  @spec schedule_rebuild(pos_integer()) :: reference()
  defp schedule_rebuild(interval_ms),
    do: Process.send_after(self(), :rebuild, interval_ms)
end
```
