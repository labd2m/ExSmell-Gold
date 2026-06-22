```elixir
defmodule Gaming.Leaderboard do
  @moduledoc """
  GenServer maintaining a real-time ranked leaderboard for a named game context.

  Scores are stored in a sorted structure enabling O(n log n) rank queries.
  Multiple leaderboard instances can be started via the registry, one per game context.
  """

  use GenServer

  alias Gaming.Leaderboard.{ScoreEntry, RankResult, Registry}

  @max_entries 1_000

  @doc """
  Starts a leaderboard process for the given context name.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    context = Keyword.fetch!(opts, :context)
    GenServer.start_link(__MODULE__, opts, name: Registry.via(context))
  end

  @doc """
  Records or updates a player's score. Higher scores replace lower ones.
  """
  @spec submit_score(String.t(), String.t(), integer()) :: :ok
  def submit_score(context, player_id, score)
      when is_binary(context) and is_binary(player_id) and is_integer(score) do
    GenServer.cast(Registry.via(context), {:submit, player_id, score})
  end

  @doc """
  Returns the top `n` ranked entries for a context.
  """
  @spec top(String.t(), pos_integer()) :: [RankResult.t()]
  def top(context, n) when is_binary(context) and is_integer(n) and n > 0 do
    GenServer.call(Registry.via(context), {:top, n})
  end

  @doc """
  Returns the rank and score of a specific player, or `nil` if not ranked.
  """
  @spec rank_of(String.t(), String.t()) :: RankResult.t() | nil
  def rank_of(context, player_id) when is_binary(context) and is_binary(player_id) do
    GenServer.call(Registry.via(context), {:rank_of, player_id})
  end

  @doc """
  Removes a player from the leaderboard.
  """
  @spec remove(String.t(), String.t()) :: :ok
  def remove(context, player_id) when is_binary(context) and is_binary(player_id) do
    GenServer.cast(Registry.via(context), {:remove, player_id})
  end

  @impl GenServer
  def init(_opts), do: {:ok, %{scores: %{}, sorted: []}}

  @impl GenServer
  def handle_cast({:submit, player_id, score}, state) do
    new_scores = Map.put(state.scores, player_id, score)
    new_sorted = rebuild_sorted(new_scores)
    trimmed = Enum.take(new_sorted, @max_entries)
    {:noreply, %{state | scores: new_scores, sorted: trimmed}}
  end

  def handle_cast({:remove, player_id}, state) do
    new_scores = Map.delete(state.scores, player_id)
    new_sorted = Enum.reject(state.sorted, &(&1.player_id == player_id))
    {:noreply, %{state | scores: new_scores, sorted: new_sorted}}
  end

  @impl GenServer
  def handle_call({:top, n}, _from, state) do
    results =
      state.sorted
      |> Enum.take(n)
      |> Enum.with_index(1)
      |> Enum.map(fn {entry, rank} -> RankResult.new(entry.player_id, entry.score, rank) end)

    {:reply, results, state}
  end

  def handle_call({:rank_of, player_id}, _from, state) do
    result =
      state.sorted
      |> Enum.with_index(1)
      |> Enum.find(fn {entry, _rank} -> entry.player_id == player_id end)
      |> case do
        nil -> nil
        {entry, rank} -> RankResult.new(entry.player_id, entry.score, rank)
      end

    {:reply, result, state}
  end

  defp rebuild_sorted(scores) do
    scores
    |> Enum.map(fn {player_id, score} -> ScoreEntry.new(player_id, score) end)
    |> Enum.sort_by(& &1.score, :desc)
  end
end

defmodule Gaming.Leaderboard.ScoreEntry do
  @moduledoc false

  @enforce_keys [:player_id, :score]
  defstruct [:player_id, :score]

  @type t :: %__MODULE__{player_id: String.t(), score: integer()}

  @spec new(String.t(), integer()) :: t()
  def new(player_id, score), do: %__MODULE__{player_id: player_id, score: score}
end

defmodule Gaming.Leaderboard.RankResult do
  @moduledoc false

  @enforce_keys [:player_id, :score, :rank]
  defstruct [:player_id, :score, :rank]

  @type t :: %__MODULE__{player_id: String.t(), score: integer(), rank: pos_integer()}

  @spec new(String.t(), integer(), pos_integer()) :: t()
  def new(player_id, score, rank), do: %__MODULE__{player_id: player_id, score: score, rank: rank}
end

defmodule Gaming.Leaderboard.Registry do
  @moduledoc false

  @spec via(String.t()) :: {:via, Registry, {module(), String.t()}}
  def via(context) when is_binary(context) do
    {:via, Registry, {Gaming.Leaderboard.ProcessRegistry, context}}
  end
end
```
