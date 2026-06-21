```elixir
defmodule Search.AutocompleteServer do
  @moduledoc """
  Serves prefix-match autocomplete suggestions from an ETS trie-like
  structure. Entries are loaded from the database at startup and can be
  incrementally updated at runtime without a full reload. Concurrent reads
  go directly to ETS so the GenServer is not a bottleneck for hot paths.
  """

  use GenServer

  @type entry :: %{id: String.t(), label: String.t(), type: String.t(), weight: non_neg_integer()}
  @type suggestion :: %{id: String.t(), label: String.t(), type: String.t()}

  @table :autocomplete_index
  @default_limit 10

  @doc "Starts the autocomplete server and builds the initial index."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns up to `limit` suggestions matching the `prefix`, ranked by weight."
  @spec suggest(String.t(), pos_integer()) :: [suggestion()]
  def suggest(prefix, limit \ @default_limit)
      when is_binary(prefix) and is_integer(limit) and limit > 0 do
    normalised = String.downcase(String.trim(prefix))

    if byte_size(normalised) == 0 do
      []
    else
      :ets.tab2list(@table)
      |> Enum.filter(fn {key, _entry} -> String.starts_with?(key, normalised) end)
      |> Enum.map(fn {_key, entry} -> entry end)
      |> Enum.sort_by(& &1.weight, :desc)
      |> Enum.take(limit)
      |> Enum.map(&to_suggestion/1)
    end
  end

  @doc "Adds or replaces an entry in the autocomplete index."
  @spec put_entry(entry()) :: :ok
  def put_entry(%{id: _, label: _, type: _, weight: _} = entry) do
    GenServer.cast(__MODULE__, {:put, entry})
  end

  @doc "Removes an entry by its ID from the autocomplete index."
  @spec remove_entry(String.t()) :: :ok
  def remove_entry(id) when is_binary(id) do
    GenServer.cast(__MODULE__, {:remove, id})
  end

  @doc "Returns the total number of indexed entries."
  @spec entry_count() :: non_neg_integer()
  def entry_count, do: :ets.info(@table, :size)

  @impl GenServer
  def init(opts) do
    :ets.new(@table, [:set, :protected, :named_table, read_concurrency: true])
    entries = Keyword.get(opts, :entries, load_from_database())
    Enum.each(entries, &index_entry/1)
    {:ok, %{}}
  end

  @impl GenServer
  def handle_cast({:put, entry}, state) do
    remove_by_id(entry.id)
    index_entry(entry)
    {:noreply, state}
  end

  def handle_cast({:remove, id}, state) do
    remove_by_id(id)
    {:noreply, state}
  end

  defp index_entry(%{label: label} = entry) do
    key = String.downcase(label)
    :ets.insert(@table, {key, entry})
  end

  defp remove_by_id(id) do
    :ets.tab2list(@table)
    |> Enum.each(fn {key, entry} ->
      if entry.id == id, do: :ets.delete(@table, key)
    end)
  end

  defp to_suggestion(%{id: id, label: label, type: type}) do
    %{id: id, label: label, type: type}
  end

  defp load_from_database do
    Application.get_env(:my_app, :autocomplete_loader, fn -> [] end).()
  end
end
```
