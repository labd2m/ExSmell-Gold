```elixir
defmodule Analytics.UserJourneyMapper do
  @moduledoc """
  Reconstructs per-user event sequences into ordered journey paths.
  A journey is the sequence of page or event names visited by a user
  in a single session. The mapper computes journey frequencies, detects
  common entry and exit points, and builds transition probability matrices
  for use in funnel analysis and UX improvement work.
  """

  @type user_id :: String.t()
  @type event_name :: String.t()
  @type session_id :: String.t()
  @type event :: %{user_id: user_id(), session_id: session_id(), name: event_name(), occurred_at: DateTime.t()}
  @type journey :: [event_name()]
  @type transition :: {event_name(), event_name()}

  @doc "Groups events into per-session journeys sorted by occurrence time."
  @spec build_journeys([event()]) :: %{session_id() => journey()}
  def build_journeys(events) when is_list(events) do
    events
    |> Enum.group_by(& &1.session_id)
    |> Map.new(fn {session_id, session_events} ->
      path =
        session_events
        |> Enum.sort_by(& &1.occurred_at, DateTime)
        |> Enum.map(& &1.name)

      {session_id, path}
    end)
  end

  @doc "Returns a frequency map of all observed journey paths."
  @spec journey_frequencies([event()]) :: %{journey() => non_neg_integer()}
  def journey_frequencies(events) when is_list(events) do
    events
    |> build_journeys()
    |> Map.values()
    |> Enum.frequencies()
  end

  @doc "Returns the most common entry points (first events) across journeys."
  @spec entry_points([event()], pos_integer()) :: [{event_name(), non_neg_integer()}]
  def entry_points(events, top_n \\ 10) when is_list(events) and is_integer(top_n) do
    events
    |> build_journeys()
    |> Map.values()
    |> Enum.flat_map(fn
      [first | _] -> [first]
      [] -> []
    end)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_name, count} -> count end, :desc)
    |> Enum.take(top_n)
  end

  @doc "Returns the most common exit points (last events) across journeys."
  @spec exit_points([event()], pos_integer()) :: [{event_name(), non_neg_integer()}]
  def exit_points(events, top_n \\ 10) when is_list(events) and is_integer(top_n) do
    events
    |> build_journeys()
    |> Map.values()
    |> Enum.flat_map(fn
      [] -> []
      path -> [List.last(path)]
    end)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_name, count} -> count end, :desc)
    |> Enum.take(top_n)
  end

  @doc "Builds a transition count matrix: how often event A is followed by event B."
  @spec transition_matrix([event()]) :: %{transition() => non_neg_integer()}
  def transition_matrix(events) when is_list(events) do
    events
    |> build_journeys()
    |> Map.values()
    |> Enum.flat_map(fn path ->
      path |> Enum.zip(tl(path))
    end)
    |> Enum.frequencies()
  end

  @doc "Returns next-step probabilities from `from_event` as a sorted list."
  @spec next_step_probabilities([event()], event_name()) :: [{event_name(), float()}]
  def next_step_probabilities(events, from_event) when is_binary(from_event) do
    matrix = transition_matrix(events)
    outgoing = matrix |> Enum.filter(fn {{a, _b}, _count} -> a == from_event end)
    total = outgoing |> Enum.sum_by(fn {_key, count} -> count end)

    if total == 0 do
      []
    else
      outgoing
      |> Enum.map(fn {{_a, b}, count} -> {b, Float.round(count / total, 4)} end)
      |> Enum.sort_by(fn {_name, prob} -> prob end, :desc)
    end
  end
end
```
