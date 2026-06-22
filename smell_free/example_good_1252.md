```elixir
defmodule Gaming.Leaderboard.ScoreBoard do
  @moduledoc """
  Maintains a real-time ranked leaderboard for a game session.
  Scores are stored in a sorted structure; rank queries are O(n log n).
  All updates are serialised through a supervised GenServer.
  """

  use GenServer

  @type player_id :: String.t()
  @type entry :: %{player_id: player_id(), score: integer(), updated_at: DateTime.t()}
  @type state :: %{entries: %{player_id() => entry()}, board_id: String.t()}

  @doc """
  Starts the ScoreBoard for the given `board_id` linked to the calling process.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    board_id = Keyword.fetch!(opts, :board_id)
    GenServer.start_link(__MODULE__, board_id, name: via(board_id))
  end

  @doc """
  Records or updates the score for `player_id` on board `board_id`.
  Only updates if the new score exceeds the existing one.
  """
  @spec submit_score(String.t(), player_id(), integer()) :: :ok | {:error, :not_found}
  def submit_score(board_id, player_id, score)
      when is_binary(board_id) and is_binary(player_id) and is_integer(score) do
    case Registry.lookup(Gaming.Registry, board_id) do
      [{pid, _}] -> GenServer.call(pid, {:submit, player_id, score})
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Returns the top `n` entries sorted by score descending.
  """
  @spec top(String.t(), pos_integer()) :: {:ok, [entry()]} | {:error, :not_found}
  def top(board_id, n) when is_binary(board_id) and is_integer(n) and n > 0 do
    case Registry.lookup(Gaming.Registry, board_id) do
      [{pid, _}] -> GenServer.call(pid, {:top, n})
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Returns the rank and entry for `player_id`, or `{:error, :not_ranked}`.
  """
  @spec rank_of(String.t(), player_id()) ::
          {:ok, %{rank: pos_integer(), entry: entry()}} | {:error, :not_found | :not_ranked}
  def rank_of(board_id, player_id) when is_binary(board_id) and is_binary(player_id) do
    case Registry.lookup(Gaming.Registry, board_id) do
      [{pid, _}] -> GenServer.call(pid, {:rank_of, player_id})
      [] -> {:error, :not_found}
    end
  end

  @impl GenServer
  def init(board_id), do: {:ok, %{entries: %{}, board_id: board_id}}

  @impl GenServer
  def handle_call({:submit, player_id, score}, _from, state) do
    existing_score = state.entries |> Map.get(player_id) |> extract_score()

    if score > existing_score do
      entry = %{player_id: player_id, score: score, updated_at: DateTime.utc_now()}
      {:reply, :ok, %{state | entries: Map.put(state.entries, player_id, entry)}}
    else
      {:reply, :ok, state}
    end
  end

  @impl GenServer
  def handle_call({:top, n}, _from, state) do
    ranked = sorted_entries(state.entries)
    {:reply, {:ok, Enum.take(ranked, n)}, state}
  end

  @impl GenServer
  def handle_call({:rank_of, player_id}, _from, state) do
    case Map.fetch(state.entries, player_id) do
      :error ->
        {:reply, {:error, :not_ranked}, state}

      {:ok, entry} ->
        rank =
          state.entries
          |> sorted_entries()
          |> Enum.find_index(fn e -> e.player_id == player_id end)

        {:reply, {:ok, %{rank: rank + 1, entry: entry}}, state}
    end
  end

  defp sorted_entries(entries) do
    entries
    |> Map.values()
    |> Enum.sort_by(fn e -> e.score end, :desc)
  end

  defp extract_score(nil), do: :math.pow(2, 53) * -1
  defp extract_score(%{score: s}), do: s

  defp via(board_id), do: {:via, Registry, {Gaming.Registry, board_id}}
end
```
