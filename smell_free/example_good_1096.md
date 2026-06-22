```elixir
defmodule Leaderboards.ScoreBoard do
  @moduledoc """
  A supervised GenServer managing an in-memory ranked leaderboard.
  Supports incremental score updates, top-N retrieval,
  and periodic persistence snapshots to a backend store.
  """

  use GenServer

  alias Leaderboards.{SnapshotStore, ScoreEntry}

  @snapshot_interval_ms 30_000

  @type player_id :: String.t()
  @type score :: non_neg_integer()
  @type rank_entry :: %{rank: pos_integer(), player_id: player_id(), score: score()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec record_score(player_id(), score()) :: :ok
  def record_score(player_id, delta) when is_binary(player_id) and is_integer(delta) do
    GenServer.cast(__MODULE__, {:record_score, player_id, delta})
  end

  @spec top(pos_integer()) :: [rank_entry()]
  def top(n) when is_integer(n) and n > 0 do
    GenServer.call(__MODULE__, {:top, n})
  end

  @spec player_rank(player_id()) :: {:ok, rank_entry()} | {:error, :not_found}
  def player_rank(player_id) when is_binary(player_id) do
    GenServer.call(__MODULE__, {:rank_of, player_id})
  end

  @impl GenServer
  def init(opts) do
    board_id = Keyword.fetch!(opts, :board_id)
    scores = SnapshotStore.load(board_id) |> Map.new(fn e -> {e.player_id, e.score} end)
    schedule_snapshot()
    {:ok, %{board_id: board_id, scores: scores}}
  end

  @impl GenServer
  def handle_cast({:record_score, player_id, delta}, state) do
    updated = Map.update(state.scores, player_id, delta, &max(0, &1 + delta))
    {:noreply, %{state | scores: updated}}
  end

  @impl GenServer
  def handle_call({:top, n}, _from, state) do
    result =
      state.scores
      |> Enum.sort_by(fn {_id, score} -> score end, :desc)
      |> Enum.take(n)
      |> Enum.with_index(1)
      |> Enum.map(fn {{player_id, score}, rank} ->
        %{rank: rank, player_id: player_id, score: score}
      end)

    {:reply, result, state}
  end

  @impl GenServer
  def handle_call({:rank_of, player_id}, _from, state) do
    sorted =
      state.scores
      |> Enum.sort_by(fn {_id, score} -> score end, :desc)
      |> Enum.with_index(1)

    result =
      Enum.find_value(sorted, {:error, :not_found}, fn {{id, score}, rank} ->
        if id == player_id, do: {:ok, %{rank: rank, player_id: id, score: score}}
      end)

    {:reply, result, state}
  end

  @impl GenServer
  def handle_info(:snapshot, state) do
    entries =
      Enum.map(state.scores, fn {id, score} ->
        %ScoreEntry{player_id: id, score: score}
      end)

    SnapshotStore.persist(state.board_id, entries)
    schedule_snapshot()
    {:noreply, state}
  end

  @spec schedule_snapshot() :: reference()
  defp schedule_snapshot do
    Process.send_after(self(), :snapshot, @snapshot_interval_ms)
  end
end
```
