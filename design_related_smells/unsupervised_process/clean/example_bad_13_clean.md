```elixir
defmodule Fraud.RuleEngine do
  use GenServer

  @moduledoc """
  Stateful fraud detection engine that evaluates transactions against
  a set of configurable rules. Maintains per-user risk scoring history
  and velocity checks using a rolling time window.
  """

  @score_threshold 75
  @window_seconds 3600
  @cleanup_interval_ms 600_000

  defstruct [
    :rules,
    :user_profiles,
    :blocked_users,
    :metrics
  ]

  def start(rules) when is_list(rules) do
    state = %__MODULE__{
      rules: rules,
      user_profiles: %{},
      blocked_users: MapSet.new(),
      metrics: %{evaluated: 0, blocked: 0, flagged: 0}
    }

    GenServer.start(__MODULE__, state, name: __MODULE__)
  end

  @doc """
  Evaluates a transaction against all rules.
  Returns {:ok, :approved}, {:ok, :flagged, score} or {:error, :blocked}.
  """
  def evaluate(transaction) do
    GenServer.call(__MODULE__, {:evaluate, transaction}, 5_000)
  end

  @doc "Manually blocks a user from transacting."
  def block_user(user_id) do
    GenServer.cast(__MODULE__, {:block_user, user_id})
  end

  @doc "Unblocks a previously blocked user."
  def unblock_user(user_id) do
    GenServer.cast(__MODULE__, {:unblock_user, user_id})
  end

  @doc "Returns current engine metrics."
  def metrics do
    GenServer.call(__MODULE__, :metrics)
  end

  @doc "Returns the current risk profile for a user."
  def user_profile(user_id) do
    GenServer.call(__MODULE__, {:user_profile, user_id})
  end

  ## Callbacks

  @impl true
  def init(state) do
    schedule_cleanup()
    {:ok, state}
  end

  @impl true
  def handle_call({:evaluate, transaction}, _from, state) do
    user_id = transaction.user_id

    if MapSet.member?(state.blocked_users, user_id) do
      metrics = Map.update!(state.metrics, :evaluated, &(&1 + 1))
      new_metrics = Map.update!(metrics, :blocked, &(&1 + 1))
      {:reply, {:error, :blocked}, %{state | metrics: new_metrics}}
    else
      {score, reasons, new_state} = run_rules(state, transaction)
      final_metrics = Map.update!(new_state.metrics, :evaluated, &(&1 + 1))

      result =
        cond do
          score >= @score_threshold ->
            Map.update!(final_metrics, :blocked, &(&1 + 1))
            {:error, :blocked}

          score >= @score_threshold / 2 ->
            Map.update!(final_metrics, :flagged, &(&1 + 1))
            {:ok, :flagged, score, reasons}

          true ->
            {:ok, :approved}
        end

      {:reply, result, %{new_state | metrics: final_metrics}}
    end
  end

  def handle_call(:metrics, _from, state) do
    {:reply, state.metrics, state}
  end

  def handle_call({:user_profile, user_id}, _from, state) do
    profile = Map.get(state.user_profiles, user_id, %{events: [], score: 0})
    {:reply, profile, state}
  end

  @impl true
  def handle_cast({:block_user, user_id}, state) do
    {:noreply, %{state | blocked_users: MapSet.put(state.blocked_users, user_id)}}
  end

  def handle_cast({:unblock_user, user_id}, state) do
    {:noreply, %{state | blocked_users: MapSet.delete(state.blocked_users, user_id)}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cutoff = DateTime.add(DateTime.utc_now(), -@window_seconds, :second)

    new_profiles =
      Map.new(state.user_profiles, fn {uid, profile} ->
        fresh_events = Enum.filter(profile.events, fn e ->
          DateTime.compare(e.occurred_at, cutoff) == :gt
        end)

        {uid, %{profile | events: fresh_events}}
      end)

    schedule_cleanup()
    {:noreply, %{state | user_profiles: new_profiles}}
  end

  defp run_rules(state, transaction) do
    {total_score, reasons, updated_profiles} =
      Enum.reduce(state.rules, {0, [], state.user_profiles}, fn rule, {score, rsns, profiles} ->
        case apply_rule(rule, transaction, profiles) do
          {:hit, rule_score, reason, new_profiles} ->
            {score + rule_score, [reason | rsns], new_profiles}

          {:miss, new_profiles} ->
            {score, rsns, new_profiles}
        end
      end)

    new_state = %{state | user_profiles: updated_profiles}
    {total_score, reasons, new_state}
  end

  defp apply_rule(%{type: :velocity, field: field, limit: limit, score: score}, txn, profiles) do
    user_id = txn.user_id
    profile = Map.get(profiles, user_id, %{events: [], score: 0})
    recent = Enum.count(profile.events, fn e -> e.type == field end)

    event = %{type: field, occurred_at: DateTime.utc_now(), value: Map.get(txn, field)}
    updated_profile = %{profile | events: [event | profile.events]}
    updated_profiles = Map.put(profiles, user_id, updated_profile)

    if recent >= limit do
      {:hit, score, {:velocity_exceeded, field}, updated_profiles}
    else
      {:miss, updated_profiles}
    end
  end

  defp apply_rule(%{type: :amount_threshold, threshold: threshold, score: score}, txn, profiles) do
    if txn.amount_cents > threshold do
      {:hit, score, {:amount_exceeded, txn.amount_cents}, profiles}
    else
      {:miss, profiles}
    end
  end

  defp apply_rule(_unknown_rule, _txn, profiles), do: {:miss, profiles}

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end
end
```
