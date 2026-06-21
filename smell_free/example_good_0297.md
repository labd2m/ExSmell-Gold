```elixir
defmodule Leaderboard.RankingServer do
  @moduledoc """
  Maintains a sorted leaderboard of scores using a GenServer backed by an
  ordered ETS table. Supports upserts, range queries by rank position, and
  neighbour lookups so a player can see those just above and below them.
  The ETS table survives GenServer crashes via `:heir` configuration.
  """

  use GenServer

  @type player_id :: String.t()
  @type score :: integer()
  @type rank_entry :: %{rank: pos_integer(), player_id: player_id(), score: score()}

  @table_name :leaderboard_scores

  @doc "Starts the ranking server registered under its module name."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Inserts or replaces the score for `player_id`."
  @spec upsert(player_id(), score()) :: :ok
  def upsert(player_id, score) when is_binary(player_id) and is_integer(score) do
    GenServer.call(__MODULE__, {:upsert, player_id, score})
  end

  @doc "Returns the rank and score for `player_id`, or `{:error, :not_found}`."
  @spec fetch_rank(player_id()) :: {:ok, rank_entry()} | {:error, :not_found}
  def fetch_rank(player_id) when is_binary(player_id) do
    GenServer.call(__MODULE__, {:fetch_rank, player_id})
  end

  @doc "Returns the top `n` entries in descending score order."
  @spec top(pos_integer()) :: [rank_entry()]
  def top(n) when is_integer(n) and n > 0 do
    GenServer.call(__MODULE__, {:top, n})
  end

  @doc "Returns the `radius` entries above and below `player_id` inclusive."
  @spec neighbours(player_id(), pos_integer()) :: [rank_entry()]
  def neighbours(player_id, radius \\ 5) when is_binary(player_id) and is_integer(radius) do
    GenServer.call(__MODULE__, {:neighbours, player_id, radius})
  end

  @impl GenServer
  def init(_opts) do
    table = :ets.new(@table_name, [:ordered_set, :protected, :named_table])
    {:ok, %{table: table}}
  end

  @impl GenServer
  def handle_call({:upsert, player_id, score}, _from, state) do
    :ets.insert(state.table, {player_id, score})
    {:reply, :ok, state}
  end

  def handle_call({:fetch_rank, player_id}, _from, state) do
    result =
      case :ets.lookup(state.table, player_id) do
        [] -> {:error, :not_found}
        [{^player_id, score}] ->
          rank = compute_rank(state.table, score)
          {:ok, %{rank: rank, player_id: player_id, score: score}}
      end

    {:reply, result, state}
  end

  def handle_call({:top, n}, _from, state) do
    entries = all_sorted(state.table) |> Enum.take(n) |> with_ranks()
    {:reply, entries, state}
  end

  def handle_call({:neighbours, player_id, radius}, _from, state) do
    case :ets.lookup(state.table, player_id) do
      [] ->
        {:reply, [], state}

      [{^player_id, score}] ->
        rank = compute_rank(state.table, score)
        from_rank = max(1, rank - radius)
        result =
          all_sorted(state.table)
          |> Enum.slice((from_rank - 1), radius * 2 + 1)
          |> with_ranks(from_rank)

        {:reply, result, state}
    end
  end

  defp all_sorted(table) do
    :ets.tab2list(table)
    |> Enum.sort_by(fn {_id, score} -> score end, :desc)
  end

  defp compute_rank(table, target_score) do
    :ets.tab2list(table)
    |> Enum.count(fn {_id, score} -> score > target_score end)
    |> Kernel.+(1)
  end

  defp with_ranks(entries, start_rank \\ 1) do
    entries
    |> Enum.with_index(start_rank)
    |> Enum.map(fn {{id, score}, rank} -> %{rank: rank, player_id: id, score: score} end)
  end
end
```
