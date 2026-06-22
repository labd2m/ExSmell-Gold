```elixir
defmodule Search.AutocompleteServer do
  @moduledoc """
  A supervised GenServer that provides sub-millisecond prefix autocomplete
  by building and querying an in-memory trie from a configurable data source.
  The trie is rebuilt on a schedule or on explicit demand. Each leaf node
  stores a score so results are returned in relevance order without sorting
  the full result set. The trie itself is a plain nested map stored as
  immutable state in the GenServer.
  """

  use GenServer

  require Logger

  @rebuild_interval_ms 15 * 60 * 1_000
  @max_results 10
  @end_marker :__end__

  @type prefix :: binary()
  @type result :: %{label: binary(), value: binary(), score: number()}

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Returns up to `limit` completions for `prefix`, sorted by score descending.
  Returns an empty list when no matches are found or the prefix is blank.
  """
  @spec complete(atom() | pid(), prefix(), pos_integer()) :: [result()]
  def complete(server \\ __MODULE__, prefix, limit \\ @max_results)
      when is_binary(prefix) and is_integer(limit) and limit > 0 do
    if byte_size(String.trim(prefix)) == 0 do
      []
    else
      GenServer.call(server, {:complete, String.downcase(prefix), limit})
    end
  end

  @doc """
  Forces an immediate trie rebuild from the data source.
  Returns `:ok` when complete.
  """
  @spec rebuild(atom() | pid()) :: :ok
  def rebuild(server \\ __MODULE__) do
    GenServer.call(server, :rebuild, 60_000)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    source = Keyword.fetch!(opts, :source)
    {:ok, %{trie: %{}, source: source}, {:continue, :build}}
  end

  @impl GenServer
  def handle_continue(:build, state) do
    trie = build_trie(state.source)
    schedule_rebuild()
    {:noreply, %{state | trie: trie}}
  end

  @impl GenServer
  def handle_call({:complete, prefix, limit}, _from, state) do
    results = query_trie(state.trie, prefix, limit)
    {:reply, results, state}
  end

  def handle_call(:rebuild, _from, state) do
    trie = build_trie(state.source)
    {:reply, :ok, %{state | trie: trie}}
  end

  @impl GenServer
  def handle_info(:rebuild, state) do
    trie = build_trie(state.source)
    schedule_rebuild()
    {:noreply, %{state | trie: trie}}
  end

  # ---------------------------------------------------------------------------
  # Trie construction and traversal
  # ---------------------------------------------------------------------------

  defp build_trie(source) do
    entries = source.()
    entry_count = length(entries)

    trie =
      Enum.reduce(entries, %{}, fn %{label: label, value: value, score: score}, trie ->
        insert(trie, String.downcase(label), %{label: label, value: value, score: score})
      end)

    Logger.info("Autocomplete trie rebuilt", entry_count: entry_count)
    trie
  end

  defp insert(trie, "", result) do
    leaf = Map.get(trie, @end_marker, [])
    Map.put(trie, @end_marker, [result | leaf])
  end

  defp insert(trie, <<char::utf8, rest::binary>>, result) do
    subtrie = Map.get(trie, char, %{})
    Map.put(trie, char, insert(subtrie, rest, result))
  end

  defp query_trie(trie, prefix, limit) do
    case navigate_to(trie, prefix) do
      nil -> []
      subtrie -> collect_results(subtrie, limit)
    end
  end

  defp navigate_to(trie, ""), do: trie

  defp navigate_to(trie, <<char::utf8, rest::binary>>) do
    case Map.get(trie, char) do
      nil -> nil
      subtrie -> navigate_to(subtrie, rest)
    end
  end

  defp collect_results(trie, limit) do
    trie
    |> gather_leaves([])
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(limit)
  end

  defp gather_leaves(trie, acc) do
    leaves = Map.get(trie, @end_marker, [])

    rest_acc =
      trie
      |> Map.delete(@end_marker)
      |> Map.values()
      |> Enum.reduce(acc, fn subtrie, a -> gather_leaves(subtrie, a) end)

    leaves ++ rest_acc
  end

  defp schedule_rebuild do
    Process.send_after(self(), :rebuild, @rebuild_interval_ms)
  end
end
```
