```elixir
defmodule LeaderboardServer do
  use GenServer

  @moduledoc """
  Maintains a live leaderboard for a game tournament or event.
  Handles score submissions, ranking computation, and tie-breaking.
  """

  @max_leaderboard_size 1000

  defstruct [
    :leaderboard_id,
    :game_id,
    :name,
    :scoring_mode,
    :started_at,
    :ends_at,
    :status,
    entries: %{}
  ]

  def start(%{leaderboard_id: id} = attrs) do
    GenServer.start(__MODULE__, attrs, name: via(id))
  end

  def submit_score(leaderboard_id, player_id, score, metadata \\ %{}) do
    GenServer.call(via(leaderboard_id), {:submit, player_id, score, metadata})
  end

  def top(leaderboard_id, n \\ 10) do
    GenServer.call(via(leaderboard_id), {:top, n})
  end

  def rank_of(leaderboard_id, player_id) do
    GenServer.call(via(leaderboard_id), {:rank, player_id})
  end

  def close_leaderboard(leaderboard_id) do
    GenServer.call(via(leaderboard_id), :close)
  end

  def stats(leaderboard_id) do
    GenServer.call(via(leaderboard_id), :stats)
  end

  defp via(id), do: {:via, Registry, {LeaderboardRegistry, id}}

  ## Callbacks

  @impl true
  def init(%{leaderboard_id: id, game_id: gid, name: name, scoring_mode: mode} = attrs) do
    state = %__MODULE__{
      leaderboard_id: id,
      game_id: gid,
      name: name,
      scoring_mode: mode,
      started_at: DateTime.utc_now(),
      ends_at: Map.get(attrs, :ends_at),
      status: :open
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:submit, player_id, score, metadata}, _from, %{status: :open} = state) do
    entry = build_or_update_entry(state.entries, player_id, score, metadata, state.scoring_mode)
    entries = Map.put(state.entries, player_id, entry)

    entries =
      if map_size(entries) > @max_leaderboard_size do
        trim_entries(entries, @max_leaderboard_size, state.scoring_mode)
      else
        entries
      end

    {:reply, {:ok, entry.score}, %{state | entries: entries}}
  end

  def handle_call({:submit, _pid, _score, _meta}, _from, state) do
    {:reply, {:error, :leaderboard_closed}, state}
  end

  def handle_call({:top, n}, _from, state) do
    ranked = rank_entries(state.entries, state.scoring_mode)
    {:reply, Enum.take(ranked, n), state}
  end

  def handle_call({:rank, player_id}, _from, state) do
    ranked = rank_entries(state.entries, state.scoring_mode)
    idx = Enum.find_index(ranked, fn {pid, _} -> pid == player_id end)
    rank = if idx, do: idx + 1, else: :not_found
    {:reply, rank, state}
  end

  def handle_call(:close, _from, state) do
    final_rankings = rank_entries(state.entries, state.scoring_mode)
    {:reply, {:ok, final_rankings}, %{state | status: :closed}}
  end

  def handle_call(:stats, _from, state) do
    stats = %{
      leaderboard_id: state.leaderboard_id,
      name: state.name,
      status: state.status,
      player_count: map_size(state.entries),
      started_at: state.started_at
    }

    {:reply, stats, state}
  end

  defp build_or_update_entry(entries, player_id, score, metadata, scoring_mode) do
    existing = Map.get(entries, player_id)

    new_score =
      case {scoring_mode, existing} do
        {:highest, nil} -> score
        {:highest, entry} -> max(entry.score, score)
        {:cumulative, nil} -> score
        {:cumulative, entry} -> entry.score + score
        {:latest, _} -> score
      end

    %{
      player_id: player_id,
      score: new_score,
      submission_count: (if existing, do: existing.submission_count + 1, else: 1),
      last_submitted_at: DateTime.utc_now(),
      metadata: metadata
    }
  end

  defp rank_entries(entries, _scoring_mode) do
    entries
    |> Enum.sort_by(fn {_pid, entry} -> entry.score end, :desc)
  end

  defp trim_entries(entries, max_size, scoring_mode) do
    entries
    |> rank_entries(scoring_mode)
    |> Enum.take(max_size)
    |> Map.new()
  end
end

defmodule GameScoring do
  @moduledoc "Public API for creating and interacting with leaderboards."

  def create_leaderboard(leaderboard_id, opts) do
    attrs = %{
      leaderboard_id: leaderboard_id,
      game_id: Keyword.fetch!(opts, :game_id),
      name: Keyword.fetch!(opts, :name),
      scoring_mode: Keyword.get(opts, :scoring_mode, :highest),
      ends_at: Keyword.get(opts, :ends_at)
    }

    case LeaderboardServer.start(attrs) do
      {:ok, _pid} -> {:ok, leaderboard_id}
      {:error, {:already_started, _}} -> {:error, :leaderboard_exists}
      {:error, reason} -> {:error, reason}
    end
  end

  def record_score(leaderboard_id, player_id, score) do
    LeaderboardServer.submit_score(leaderboard_id, player_id, score)
  end

  def rankings(leaderboard_id, top_n \\ 10) do
    LeaderboardServer.top(leaderboard_id, top_n)
  end
end
```
