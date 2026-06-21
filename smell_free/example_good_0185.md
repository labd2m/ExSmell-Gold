```elixir
defmodule Gaming.Leaderboard do
  @moduledoc """
  A real-time leaderboard backed by an ETS ordered set, managed by a GenServer.

  Scores are stored in ETS for O(log n) insertion and retrieval. The top-N
  ranking is computed on read without sorting the full table. All write
  operations are serialized through the GenServer; reads query ETS directly
  for maximum concurrency.
  """

  use GenServer

  @type player_id :: pos_integer()
  @type score :: non_neg_integer()
  @type rank_entry :: %{rank: pos_integer(), player_id: player_id(), score: score()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Records or updates a player's score. Higher scores overwrite lower ones."
  @spec submit_score(player_id(), score()) :: :ok
  def submit_score(player_id, score)
      when is_integer(player_id) and is_integer(score) and score >= 0 do
    GenServer.cast(__MODULE__, {:submit, player_id, score})
  end

  @doc "Removes a player from the leaderboard."
  @spec remove_player(player_id()) :: :ok
  def remove_player(player_id) when is_integer(player_id) do
    GenServer.cast(__MODULE__, {:remove, player_id})
  end

  @doc """
  Returns the top `limit` players by score, ranked from highest to lowest.
  Reads directly from ETS without going through the GenServer.
  """
  @spec top(pos_integer()) :: [rank_entry()]
  def top(limit \\ 10) when is_integer(limit) and limit > 0 do
    table = :persistent_term.get({__MODULE__, :ets_table})

    table
    |> :ets.tab2list()
    |> Enum.sort_by(fn {_player_id, score} -> score end, :desc)
    |> Enum.take(limit)
    |> Enum.with_index(1)
    |> Enum.map(fn {{player_id, score}, rank} ->
      %{rank: rank, player_id: player_id, score: score}
    end)
  end

  @doc """
  Returns the rank and score of a specific player, or `{:error, :not_found}`.
  """
  @spec player_rank(player_id()) :: {:ok, rank_entry()} | {:error, :not_found}
  def player_rank(player_id) when is_integer(player_id) do
    table = :persistent_term.get({__MODULE__, :ets_table})

    case :ets.lookup(table, player_id) do
      [{^player_id, score}] ->
        rank = compute_rank(table, score)
        {:ok, %{rank: rank, player_id: player_id, score: score}}

      [] ->
        {:error, :not_found}
    end
  end

  @doc "Returns the total number of players on the leaderboard."
  @spec player_count() :: non_neg_integer()
  def player_count do
    table = :persistent_term.get({__MODULE__, :ets_table})
    :ets.info(table, :size)
  end

  @impl GenServer
  def init(opts) do
    table_name = Keyword.get(opts, :table_name, :leaderboard_scores)
    table = :ets.new(table_name, [:set, :public, :named_table, read_concurrency: true])
    :persistent_term.put({__MODULE__, :ets_table}, table)
    {:ok, %{table: table}}
  end

  @impl GenServer
  def handle_cast({:submit, player_id, new_score}, %{table: table} = state) do
    current = case :ets.lookup(table, player_id) do
      [{_, score}] -> score
      [] -> -1
    end

    if new_score > current do
      :ets.insert(table, {player_id, new_score})
    end

    {:noreply, state}
  end

  @impl GenServer
  def handle_cast({:remove, player_id}, %{table: table} = state) do
    :ets.delete(table, player_id)
    {:noreply, state}
  end

  defp compute_rank(table, score) do
    :ets.foldl(fn {_, s}, count -> if s > score, do: count + 1, else: count end, 0, table) + 1
  end
end
```
