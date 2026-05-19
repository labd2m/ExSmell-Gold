# Annotated Example 21 — Unsupervised Process

- **Smell name:** Unsupervised Process
- **Expected smell location:** `Sports.MatchTracker.start/1`
- **Affected function(s):** `start/1`
- **Short explanation:** Each live match spawns its own GenServer via `GenServer.start/3` outside any supervision tree. A crash mid-match silently discards all score and event state, with no automatic restart, leaving clients serving stale or absent data.

```elixir
defmodule Sports.MatchTracker do
  use GenServer

  @moduledoc """
  Tracks the real-time state of a single live sports match.
  Manages score updates, match clock, period transitions, and
  a running event log (goals, cards, substitutions). Broadcasts
  diffs to downstream score-feed consumers.
  """

  @clock_tick_ms 1_000
  @max_event_log 200

  defstruct [
    :match_id,
    :home_team,
    :away_team,
    :competition,
    :score,
    :period,
    :clock_seconds,
    :status,
    :events,
    :started_at,
    :last_updated_at
  ]

  # VALIDATION: SMELL START - Unsupervised Process
  # VALIDATION: This is a smell because `GenServer.start/3` creates a long-running
  # live match tracker outside any supervision tree. During a busy sports calendar
  # there may be dozens of concurrent matches, each with its own unsupervised process.
  # If a process crashes (e.g., due to a malformed event payload from the data
  # provider), the authoritative in-memory match state is permanently lost. No
  # supervisor is present to restart the tracker, so consumers receive no further
  # updates and the match disappears from live listings with no operator alert.
  def start(match_attrs) do
    state = %__MODULE__{
      match_id: match_attrs.id,
      home_team: match_attrs.home_team,
      away_team: match_attrs.away_team,
      competition: match_attrs.competition,
      score: %{home: 0, away: 0},
      period: :pre_match,
      clock_seconds: 0,
      status: :scheduled,
      events: [],
      started_at: nil,
      last_updated_at: DateTime.utc_now()
    }

    GenServer.start(__MODULE__, state, name: via_name(match_attrs.id))
  end
  # VALIDATION: SMELL END

  @doc "Transitions the match to the given period (:first_half, :second_half, :ft, etc.)."
  def set_period(match_id, period) do
    GenServer.call(via_name(match_id), {:set_period, period})
  end

  @doc "Records a goal for the given side (:home or :away)."
  def record_goal(match_id, side, scorer, minute) when side in [:home, :away] do
    GenServer.call(via_name(match_id), {:goal, side, scorer, minute})
  end

  @doc "Records a disciplinary event (:yellow_card or :red_card)."
  def record_card(match_id, team, player, type, minute) do
    GenServer.cast(via_name(match_id), {:card, team, player, type, minute})
  end

  @doc "Records a substitution."
  def record_substitution(match_id, team, player_off, player_on, minute) do
    GenServer.cast(via_name(match_id), {:substitution, team, player_off, player_on, minute})
  end

  @doc "Returns the current match snapshot."
  def snapshot(match_id) do
    GenServer.call(via_name(match_id), :snapshot)
  end

  @doc "Returns the event log in chronological order."
  def event_log(match_id) do
    GenServer.call(via_name(match_id), :event_log)
  end

  ## Callbacks

  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  def handle_call({:set_period, :first_half}, _from, %{status: :scheduled} = state) do
    new_state = %{
      state
      | period: :first_half,
        status: :live,
        started_at: DateTime.utc_now(),
        clock_seconds: 0
    }

    schedule_tick()
    {:reply, :ok, new_state}
  end

  def handle_call({:set_period, period}, _from, state) do
    new_state = %{state | period: period, last_updated_at: DateTime.utc_now()}

    final_state =
      if period == :full_time do
        %{new_state | status: :finished}
      else
        new_state
      end

    {:reply, :ok, final_state}
  end

  def handle_call({:goal, side, scorer, minute}, _from, state) do
    new_score = Map.update!(state.score, side, &(&1 + 1))

    event = build_event(:goal, %{side: side, scorer: scorer, minute: minute})

    new_state =
      state
      |> Map.put(:score, new_score)
      |> append_event(event)

    broadcast_update(new_state, event)
    {:reply, {:ok, new_state.score}, new_state}
  end

  def handle_call(:snapshot, _from, state) do
    snap = %{
      match_id: state.match_id,
      home_team: state.home_team,
      away_team: state.away_team,
      competition: state.competition,
      score: state.score,
      period: state.period,
      clock_seconds: state.clock_seconds,
      status: state.status,
      event_count: length(state.events),
      started_at: state.started_at,
      last_updated_at: state.last_updated_at
    }

    {:reply, snap, state}
  end

  def handle_call(:event_log, _from, state) do
    {:reply, Enum.reverse(state.events), state}
  end

  @impl true
  def handle_cast({:card, team, player, type, minute}, state) do
    event = build_event(type, %{team: team, player: player, minute: minute})
    {:noreply, append_event(state, event)}
  end

  def handle_cast({:substitution, team, player_off, player_on, minute}, state) do
    event = build_event(:substitution, %{
      team: team,
      player_off: player_off,
      player_on: player_on,
      minute: minute
    })

    {:noreply, append_event(state, event)}
  end

  @impl true
  def handle_info(:tick, %{status: :live} = state) do
    schedule_tick()
    {:noreply, %{state | clock_seconds: state.clock_seconds + 1}}
  end

  def handle_info(:tick, state), do: {:noreply, state}

  defp append_event(state, event) do
    trimmed = Enum.take([event | state.events], @max_event_log)
    %{state | events: trimmed, last_updated_at: DateTime.utc_now()}
  end

  defp build_event(type, attrs) do
    Map.merge(attrs, %{type: type, occurred_at: DateTime.utc_now()})
  end

  defp broadcast_update(_state, _event), do: :ok

  defp schedule_tick do
    Process.send_after(self(), :tick, @clock_tick_ms)
  end

  defp via_name(match_id) do
    {:via, Registry, {Sports.MatchRegistry, match_id}}
  end
end
```
