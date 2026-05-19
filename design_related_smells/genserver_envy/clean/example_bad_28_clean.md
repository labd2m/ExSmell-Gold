```elixir
defmodule MyApp.LeaderboardTask do
  @moduledoc """
  Real-time leaderboard for gamification features.
  Tracks scores per competition window, computes ranks, and handles ties.
  """

  alias MyApp.{Repo, NotificationService, MetricsCollector}
  alias MyApp.Gamification.{ScoreEntry, RankChange, Competition}

  @top_n 100
  @rank_change_notify_threshold 10

  def start_leaderboard(competition) do
    Task.start_link(fn ->
      existing_scores =
        Repo.scores_for_competition(competition.id)
        |> Enum.into(%{}, &{&1.player_id, &1})

      state = %{
        competition: competition,
        scores: existing_scores,
        rank_history: %{},
        last_recomputed_at: DateTime.utc_now()
      }

      leaderboard_loop(state)
    end)
  end

  defp leaderboard_loop(state) do
    receive do
      {:submit_score, from, player_id, points, metadata} ->
        now = DateTime.utc_now()

        existing = Map.get(state.scores, player_id)

        updated_entry =
          case existing do
            nil ->
              %ScoreEntry{
                player_id: player_id,
                competition_id: state.competition.id,
                points: points,
                submission_count: 1,
                best_submission: points,
                last_submitted_at: now,
                metadata: metadata
              }

            entry ->
              %{
                entry
                | points: entry.points + points,
                  submission_count: entry.submission_count + 1,
                  best_submission: max(entry.best_submission, points),
                  last_submitted_at: now
              }
          end

        Repo.upsert_score(updated_entry)
        new_scores = Map.put(state.scores, player_id, updated_entry)

        old_rank = get_rank(state.scores, player_id)
        new_rank = get_rank(new_scores, player_id)
        rank_delta = old_rank - new_rank

        new_history =
          if rank_delta != 0 do
            change = %RankChange{
              player_id: player_id,
              old_rank: old_rank,
              new_rank: new_rank,
              changed_at: now
            }

            Map.update(state.rank_history, player_id, [change], &[change | Enum.take(&1, 49)])
          else
            state.rank_history
          end

        if abs(rank_delta) >= @rank_change_notify_threshold do
          NotificationService.notify(player_id, :rank_changed, %{
            old: old_rank,
            new: new_rank,
            delta: rank_delta
          })
        end

        MetricsCollector.counter(:leaderboard_submissions, 1)
        send(from, {:ok, %{new_rank: new_rank, total_points: updated_entry.points}})
        leaderboard_loop(%{state | scores: new_scores, rank_history: new_history})

      {:get_rank, from, player_id} ->
        rank = get_rank(state.scores, player_id)
        entry = Map.get(state.scores, player_id)
        send(from, {:ok, %{rank: rank, entry: entry}})
        leaderboard_loop(state)

      {:get_top, from, n} ->
        top =
          state.scores
          |> Map.values()
          |> Enum.sort_by(& &1.points, :desc)
          |> Enum.take(min(n, @top_n))
          |> Enum.with_index(1)
          |> Enum.map(fn {entry, rank} -> Map.put(entry, :rank, rank) end)

        send(from, {:ok, top})
        leaderboard_loop(state)

      {:get_around, from, player_id, window} ->
        rank = get_rank(state.scores, player_id)
        lo = max(1, rank - window)
        hi = rank + window

        surrounding =
          state.scores
          |> Map.values()
          |> Enum.sort_by(& &1.points, :desc)
          |> Enum.with_index(1)
          |> Enum.filter(fn {_, r} -> r >= lo and r <= hi end)
          |> Enum.map(fn {entry, r} -> Map.put(entry, :rank, r) end)

        send(from, {:ok, surrounding})
        leaderboard_loop(state)

      {:get_stats, from} ->
        total = map_size(state.scores)
        total_points = state.scores |> Map.values() |> Enum.map(& &1.points) |> Enum.sum()
        send(from, {:ok, %{participants: total, total_points: total_points}})
        leaderboard_loop(state)

      :stop ->
        :ok
    end
  end

  defp get_rank(scores, player_id) do
    sorted = scores |> Map.values() |> Enum.sort_by(& &1.points, :desc)
    idx = Enum.find_index(sorted, &(&1.player_id == player_id))
    if idx, do: idx + 1, else: map_size(scores) + 1
  end

  def submit_score(pid, player_id, points, metadata \\ %{}) do
    send(pid, {:submit_score, self(), player_id, points, metadata})

    receive do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    after
      5_000 -> {:error, :timeout}
    end
  end

  def get_top(pid, n \\ 10) do
    send(pid, {:get_top, self(), n})

    receive do
      {:ok, top} -> {:ok, top}
    after
      5_000 -> {:error, :timeout}
    end
  end
end
```
