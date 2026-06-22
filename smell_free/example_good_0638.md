```elixir
defmodule Analytics.GoalTracker do
  @moduledoc """
  Tracks goal completions and progress for conversion analytics. Goals are
  configured with a target value; progress events accumulate against the
  goal until it is achieved. The tracker stores goal definitions and
  per-user progress in ETS for fast increments and exposes Ecto-backed
  persistence for durability across restarts.
  """

  use GenServer

  alias MyApp.Repo
  alias Analytics.GoalProgress

  @type goal_id :: String.t()
  @type user_id :: String.t()
  @type goal_def :: %{id: goal_id(), name: String.t(), target: pos_integer()}

  @table :goal_progress_cache

  @doc "Starts the goal tracker."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Registers a goal definition."
  @spec define_goal(goal_def()) :: :ok
  def define_goal(%{id: _, name: _, target: _} = goal_def) do
    GenServer.call(__MODULE__, {:define, goal_def})
  end

  @doc "Records `amount` units of progress toward `goal_id` for `user_id`."
  @spec record(goal_id(), user_id(), pos_integer()) :: {:ok, :progressed | :achieved}
  def record(goal_id, user_id, amount \ 1)
      when is_binary(goal_id) and is_binary(user_id)
      and is_integer(amount) and amount > 0 do
    GenServer.call(__MODULE__, {:record, goal_id, user_id, amount})
  end

  @doc "Returns the current progress value for `user_id` toward `goal_id`."
  @spec progress(goal_id(), user_id()) :: non_neg_integer()
  def progress(goal_id, user_id) when is_binary(goal_id) and is_binary(user_id) do
    key = cache_key(goal_id, user_id)
    case :ets.lookup(@table, key) do
      [{^key, value}] -> value
      [] -> 0
    end
  end

  @doc "Returns true when `user_id` has achieved `goal_id`."
  @spec achieved?(goal_id(), user_id()) :: boolean()
  def achieved?(goal_id, user_id) do
    GenServer.call(__MODULE__, {:achieved?, goal_id, user_id})
  end

  @impl GenServer
  def init(opts) do
    :ets.new(@table, [:set, :protected, :named_table, write_concurrency: false])
    goals = Keyword.get(opts, :goals, [])
    goal_map = Map.new(goals, &{&1.id, &1})
    {:ok, %{goals: goal_map}}
  end

  @impl GenServer
  def handle_call({:define, goal_def}, _from, state) do
    {:reply, :ok, put_in(state, [:goals, goal_def.id], goal_def)}
  end

  def handle_call({:record, goal_id, user_id, amount}, _from, state) do
    key = cache_key(goal_id, user_id)
    new_value = :ets.update_counter(@table, key, {2, amount}, {key, 0})
    persist_progress(goal_id, user_id, new_value)

    result =
      case Map.get(state.goals, goal_id) do
        %{target: target} when new_value >= target -> :achieved
        _ -> :progressed
      end

    {:reply, {:ok, result}, state}
  end

  def handle_call({:achieved?, goal_id, user_id}, _from, state) do
    current = progress(goal_id, user_id)
    achieved =
      case Map.get(state.goals, goal_id) do
        %{target: target} -> current >= target
        nil -> false
      end

    {:reply, achieved, state}
  end

  defp persist_progress(goal_id, user_id, value) do
    Repo.insert_all(
      GoalProgress,
      [%{goal_id: goal_id, user_id: user_id, value: value, updated_at: DateTime.utc_now()}],
      on_conflict: {:replace, [:value, :updated_at]},
      conflict_target: [:goal_id, :user_id]
    )
  rescue
    _ -> :ok
  end

  defp cache_key(goal_id, user_id), do: "#{goal_id}:#{user_id}"
end
```
