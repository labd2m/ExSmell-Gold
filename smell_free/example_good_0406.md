```elixir
defmodule Analytics.FunnelAnalyser do
  @moduledoc """
  Computes conversion funnel metrics from a flat list of user events.
  Each funnel is defined as an ordered sequence of event types. The
  analyser tracks per-user progression through the funnel and reports
  drop-off at each step. All computation is pure and operates on
  in-memory event lists.
  """

  @type event :: %{user_id: String.t(), type: String.t(), occurred_at: DateTime.t()}
  @type funnel :: [String.t()]
  @type step_stats :: %{
          step: String.t(),
          entered: non_neg_integer(),
          converted: non_neg_integer(),
          conversion_rate: float(),
          drop_off: non_neg_integer()
        }
  @type funnel_report :: %{
          funnel: funnel(),
          steps: [step_stats()],
          overall_conversion_rate: float()
        }

  @doc """
  Analyses `events` against the `funnel` definition and returns a full
  conversion report with per-step and overall conversion rates.
  """
  @spec analyse([event()], funnel()) :: funnel_report()
  def analyse(events, [_ | _] = funnel) when is_list(events) do
    by_user = group_by_user(events)
    step_counts = compute_step_counts(by_user, funnel)
    steps = build_step_stats(funnel, step_counts)
    overall = overall_rate(steps)
    %{funnel: funnel, steps: steps, overall_conversion_rate: overall}
  end

  @doc "Returns the set of user IDs who completed the entire funnel."
  @spec completions([event()], funnel()) :: MapSet.t()
  def completions(events, funnel) when is_list(events) and is_list(funnel) do
    events
    |> group_by_user()
    |> Enum.filter(fn {_uid, user_events} -> completed_funnel?(user_events, funnel) end)
    |> Enum.map(fn {uid, _} -> uid end)
    |> MapSet.new()
  end

  defp group_by_user(events) do
    events
    |> Enum.group_by(& &1.user_id)
    |> Map.new(fn {uid, evts} ->
      sorted = Enum.sort_by(evts, & &1.occurred_at, DateTime)
      {uid, sorted}
    end)
  end

  defp compute_step_counts(by_user, funnel) do
    funnel
    |> Enum.with_index()
    |> Map.new(fn {step, idx} ->
      partial_funnel = Enum.take(funnel, idx + 1)
      count = Enum.count(by_user, fn {_uid, evts} -> reached_step?(evts, partial_funnel) end)
      {step, count}
    end)
  end

  defp reached_step?(user_events, partial_funnel) do
    types = Enum.map(user_events, & &1.type)
    match_sequence(types, partial_funnel)
  end

  defp completed_funnel?(user_events, funnel) do
    reached_step?(user_events, funnel)
  end

  defp match_sequence(_types, []), do: true
  defp match_sequence([], _funnel), do: false

  defp match_sequence([type | rest_types], [step | rest_steps]) do
    if type == step do
      match_sequence(rest_types, rest_steps)
    else
      match_sequence(rest_types, [step | rest_steps])
    end
  end

  defp build_step_stats(funnel, step_counts) do
    funnel
    |> Enum.with_index()
    |> Enum.map(fn {step, idx} ->
      entered = step_counts[step] || 0
      converted = if idx + 1 < length(funnel), do: step_counts[Enum.at(funnel, idx + 1)] || 0, else: entered
      drop_off = entered - converted
      rate = if entered > 0, do: Float.round(converted / entered * 100, 1), else: 0.0
      %{step: step, entered: entered, converted: converted, conversion_rate: rate, drop_off: drop_off}
    end)
  end

  defp overall_rate([]), do: 0.0

  defp overall_rate(steps) do
    first = List.first(steps)
    last = List.last(steps)
    if first.entered > 0, do: Float.round(last.entered / first.entered * 100, 1), else: 0.0
  end
end
```
