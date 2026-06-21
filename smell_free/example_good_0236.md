# File: `example_good_236.md`

```elixir
defmodule Monitoring.AlertManager do
  @moduledoc """
  GenServer that evaluates metric samples against registered alert rules
  and dispatches notifications through a configured handler when thresholds
  are breached.

  Alert state is tracked to prevent notification floods: an alert fires
  once when it transitions to a breached state and again when it recovers,
  but not on every sample while already breached.
  """

  use GenServer

  require Logger

  @type metric_name :: atom()
  @type sample_value :: number()
  @type comparator :: :gt | :gte | :lt | :lte | :eq

  @type rule :: %{
          required(:name) => atom(),
          required(:metric) => metric_name(),
          required(:comparator) => comparator(),
          required(:threshold) => number(),
          required(:severity) => :info | :warning | :critical
        }

  @type alert_state :: :ok | :firing

  @doc false
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers an alert rule. Replaces any existing rule with the same name.
  """
  @spec register_rule(rule()) :: :ok
  def register_rule(%{name: _} = rule) do
    GenServer.cast(__MODULE__, {:register_rule, rule})
  end

  @doc """
  Removes a registered alert rule by name.
  """
  @spec remove_rule(atom()) :: :ok
  def remove_rule(rule_name) when is_atom(rule_name) do
    GenServer.cast(__MODULE__, {:remove_rule, rule_name})
  end

  @doc """
  Submits a metric sample for evaluation against all matching rules.
  """
  @spec record(metric_name(), sample_value()) :: :ok
  def record(metric, value) when is_atom(metric) and is_number(value) do
    GenServer.cast(__MODULE__, {:record, metric, value})
  end

  @doc """
  Returns the current firing/ok state for all registered rules.
  """
  @spec alert_states() :: %{atom() => alert_state()}
  def alert_states do
    GenServer.call(__MODULE__, :alert_states)
  end

  @impl GenServer
  def init(opts) do
    handler = Keyword.fetch!(opts, :handler)
    {:ok, %{rules: [], states: %{}, handler: handler}}
  end

  @impl GenServer
  def handle_cast({:register_rule, rule}, state) do
    existing = Enum.reject(state.rules, &(&1.name == rule.name))
    {:noreply, %{state | rules: [rule | existing]}}
  end

  @impl GenServer
  def handle_cast({:remove_rule, name}, state) do
    {:noreply, %{state |
      rules: Enum.reject(state.rules, &(&1.name == name)),
      states: Map.delete(state.states, name)
    }}
  end

  @impl GenServer
  def handle_cast({:record, metric, value}, state) do
    matching_rules = Enum.filter(state.rules, &(&1.metric == metric))
    new_state = Enum.reduce(matching_rules, state, &evaluate_rule(&2, &1, value))
    {:noreply, new_state}
  end

  @impl GenServer
  def handle_call(:alert_states, _from, state) do
    {:reply, state.states, state}
  end

  defp evaluate_rule(state, rule, value) do
    breached = threshold_breached?(rule.comparator, value, rule.threshold)
    previous_state = Map.get(state.states, rule.name, :ok)
    new_alert_state = if breached, do: :firing, else: :ok

    state_changed = new_alert_state != previous_state

    if state_changed do
      dispatch_notification(state.handler, rule, value, new_alert_state)
    end

    %{state | states: Map.put(state.states, rule.name, new_alert_state)}
  end

  defp threshold_breached?(:gt, value, threshold), do: value > threshold
  defp threshold_breached?(:gte, value, threshold), do: value >= threshold
  defp threshold_breached?(:lt, value, threshold), do: value < threshold
  defp threshold_breached?(:lte, value, threshold), do: value <= threshold
  defp threshold_breached?(:eq, value, threshold), do: value == threshold

  defp dispatch_notification(handler, rule, value, :firing) do
    Logger.warning("Alert firing: #{rule.name} (#{rule.metric} = #{value})")
    handler.on_alert(%{rule: rule, value: value, state: :firing, fired_at: DateTime.utc_now()})
  end

  defp dispatch_notification(handler, rule, value, :ok) do
    Logger.info("Alert recovered: #{rule.name} (#{rule.metric} = #{value})")
    handler.on_recovery(%{rule: rule, value: value, state: :ok, recovered_at: DateTime.utc_now()})
  end
end
```
