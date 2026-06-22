# File: `example_good_708.md`

```elixir
defmodule Analytics.GoalTracker do
  @moduledoc """
  Tracks user progress toward named conversion goals defined as
  sequences of required events. A goal is achieved when a user
  completes all required steps within an optional time window.

  Goals are defined declaratively and evaluated against stored event
  records. The tracker writes completion facts to a separate table
  so downstream analytics can query goal counts without re-evaluating
  event streams.
  """

  import Ecto.Query, warn: false

  alias Analytics.{EventLog, GoalCompletion, Repo}

  @type user_id :: String.t()
  @type goal_name :: String.t()
  @type event_type :: String.t()

  @type goal_definition :: %{
          required(:name) => goal_name(),
          required(:steps) => [event_type()],
          optional(:window_hours) => pos_integer()
        }

  @type evaluation_result :: %{
          user_id: user_id(),
          goal: goal_name(),
          completed: boolean(),
          completed_at: DateTime.t() | nil,
          steps_completed: non_neg_integer(),
          steps_required: non_neg_integer()
        }

  @doc """
  Evaluates whether `user_id` has completed `goal` based on their
  stored event log.

  Returns an `evaluation_result` describing progress regardless of
  whether the goal was completed.
  """
  @spec evaluate(user_id(), goal_definition()) :: evaluation_result()
  def evaluate(user_id, %{name: name, steps: steps} = goal)
      when is_binary(user_id) and is_list(steps) do
    window_hours = Map.get(goal, :window_hours)
    events = fetch_events(user_id, steps, window_hours)

    {completed, completed_at, steps_done} = check_completion(events, steps)

    %{
      user_id: user_id,
      goal: name,
      completed: completed,
      completed_at: completed_at,
      steps_completed: steps_done,
      steps_required: length(steps)
    }
  end

  @doc """
  Records a goal completion if not already recorded, then returns
  the completion record.

  Returns `{:ok, completion}` or `{:error, :not_completed}` when the
  goal has not actually been achieved.
  """
  @spec record_completion(user_id(), goal_definition()) ::
          {:ok, GoalCompletion.t()} | {:error, :not_completed | Ecto.Changeset.t()}
  def record_completion(user_id, goal) do
    result = evaluate(user_id, goal)

    if result.completed do
      upsert_completion(user_id, goal.name, result.completed_at)
    else
      {:error, :not_completed}
    end
  end

  @doc """
  Returns the count of unique users who have completed a named goal.
  """
  @spec completion_count(goal_name()) :: non_neg_integer()
  def completion_count(goal_name) when is_binary(goal_name) do
    GoalCompletion
    |> where([c], c.goal_name == ^goal_name)
    |> select([c], count(c.id, :distinct))
    |> Repo.one()
  end

  @doc """
  Returns all users who completed a goal within a date range.
  """
  @spec completions_in_range(goal_name(), DateTime.t(), DateTime.t()) :: [GoalCompletion.t()]
  def completions_in_range(goal_name, from, to) do
    GoalCompletion
    |> where([c], c.goal_name == ^goal_name and c.completed_at >= ^from and c.completed_at <= ^to)
    |> order_by([c], asc: c.completed_at)
    |> Repo.all()
  end

  defp fetch_events(user_id, steps, nil) do
    EventLog
    |> where([e], e.user_id == ^user_id and e.event_type in ^steps)
    |> order_by([e], asc: e.occurred_at)
    |> Repo.all()
  end

  defp fetch_events(user_id, steps, window_hours) do
    cutoff = DateTime.add(DateTime.utc_now(), -window_hours * 3600, :second)

    EventLog
    |> where([e], e.user_id == ^user_id and e.event_type in ^steps and e.occurred_at >= ^cutoff)
    |> order_by([e], asc: e.occurred_at)
    |> Repo.all()
  end

  defp check_completion(events, steps) do
    {steps_done, last_event, remaining} =
      Enum.reduce_while(steps, {0, nil, events}, fn step, {count, _last, remaining_events} ->
        case Enum.find_index(remaining_events, &(&1.event_type == step)) do
          nil ->
            {:halt, {count, nil, remaining_events}}

          idx ->
            matched = Enum.at(remaining_events, idx)
            {:cont, {count + 1, matched, Enum.drop(remaining_events, idx + 1)}}
        end
      end)

    completed = steps_done == length(steps)
    completed_at = if completed and last_event, do: last_event.occurred_at, else: nil
    {completed, completed_at, steps_done}
  end

  defp upsert_completion(user_id, goal_name, completed_at) do
    %{user_id: user_id, goal_name: goal_name, completed_at: completed_at}
    |> GoalCompletion.changeset()
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:user_id, :goal_name])
  end
end
```
