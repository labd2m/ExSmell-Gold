# Annotated Example – Bad Code

- **Smell name:** Agent Obsession
- **Expected smell location:** Modules `EventCollector`, `ReportAggregator`, `ReportExporter`, and `AlertEvaluator`
- **Affected functions:** `EventCollector.record/2`, `ReportAggregator.aggregate/2`, `ReportExporter.export/3`, `AlertEvaluator.check_thresholds/1`
- **Short explanation:** Four different modules directly read and write the shared analytics Agent. None delegates to a single owner, causing the internal event list and aggregates map to be implicitly shared in format across the system.

```elixir
defmodule AnalyticsAgent do
  @moduledoc "Agent holding raw events and pre-computed aggregates."

  def start_link(_opts \\ []) do
    Agent.start_link(
      fn ->
        %{
          events: [],
          aggregates: %{},
          alerts: []
        }
      end,
      name: __MODULE__
    )
  end

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :permanent}
  end
end

# VALIDATION: SMELL START - Agent Obsession
# VALIDATION: This is a smell because EventCollector directly calls Agent.update to
# prepend new event records to the Agent's internal events list, owning that list
# format without a central interface.
defmodule EventCollector do
  @moduledoc "Records raw analytics events from application modules."

  require Logger

  @valid_event_types [
    :page_view,
    :button_click,
    :form_submit,
    :api_call,
    :error,
    :purchase,
    :login,
    :logout
  ]

  def record(agent, %{type: type, user_id: user_id, properties: props} = event)
      when type in @valid_event_types do
    entry = %{
      id: :crypto.strong_rand_bytes(8) |> Base.encode16(),
      type: type,
      user_id: user_id,
      properties: props,
      session_id: Map.get(event, :session_id),
      source: Map.get(event, :source, :web),
      timestamp: DateTime.utc_now()
    }

    Agent.update(agent, fn state ->
      %{state | events: [entry | state.events]}
    end)

    Logger.debug("Recorded #{type} event for user #{user_id}")
    {:ok, entry.id}
  end

  def record(_agent, %{type: type}), do: {:error, {:unknown_event_type, type}}
end
# VALIDATION: SMELL END

# VALIDATION: SMELL START - Agent Obsession
# VALIDATION: This is a smell because ReportAggregator directly calls Agent.get to read
# raw events and Agent.update to write computed aggregates back, making aggregation
# logic responsible for both computing and persisting results via the Agent directly.
defmodule ReportAggregator do
  @moduledoc "Computes aggregated metrics from collected raw events."

  def aggregate(agent, period_key) do
    events = Agent.get(agent, fn state -> state.events end)

    counts_by_type =
      Enum.reduce(events, %{}, fn e, acc ->
        Map.update(acc, e.type, 1, &(&1 + 1))
      end)

    unique_users =
      events
      |> Enum.map(& &1.user_id)
      |> Enum.uniq()
      |> length()

    purchase_revenue =
      events
      |> Enum.filter(&(&1.type == :purchase))
      |> Enum.map(&Map.get(&1.properties, :amount, 0))
      |> Enum.sum()

    error_rate =
      case Map.get(counts_by_type, :api_call, 0) do
        0 -> 0.0
        calls -> Float.round(Map.get(counts_by_type, :error, 0) / calls * 100, 2)
      end

    summary = %{
      period: period_key,
      event_counts: counts_by_type,
      unique_users: unique_users,
      purchase_revenue: purchase_revenue,
      error_rate: error_rate,
      computed_at: DateTime.utc_now()
    }

    Agent.update(agent, fn state ->
      %{state | aggregates: Map.put(state.aggregates, period_key, summary)}
    end)

    {:ok, summary}
  end
end
# VALIDATION: SMELL END

# VALIDATION: SMELL START - Agent Obsession
# VALIDATION: This is a smell because ReportExporter directly calls Agent.get to read
# both raw events and aggregates from the Agent, coupling the export format to the
# Agent's internal data representation.
defmodule ReportExporter do
  @moduledoc "Exports analytics data in various formats."

  def export(agent, period_key, format \\ :json) do
    aggregate = Agent.get(agent, fn state -> Map.get(state.aggregates, period_key) end)

    if is_nil(aggregate) do
      {:error, :aggregate_not_found}
    else
      case format do
        :json -> {:ok, Jason.encode!(aggregate)}
        :csv -> {:ok, to_csv(aggregate)}
        :summary -> {:ok, format_summary(aggregate)}
        _ -> {:error, :unsupported_format}
      end
    end
  end

  def raw_event_dump(agent, event_type) do
    Agent.get(agent, fn state ->
      Enum.filter(state.events, &(&1.type == event_type))
    end)
  end

  defp to_csv(%{period: p, unique_users: u, purchase_revenue: r, error_rate: e}) do
    "period,unique_users,purchase_revenue,error_rate\n#{p},#{u},#{r},#{e}\n"
  end

  defp format_summary(%{period: p, unique_users: u, purchase_revenue: r}) do
    "Period: #{p} | Users: #{u} | Revenue: $#{r}"
  end
end
# VALIDATION: SMELL END

# VALIDATION: SMELL START - Agent Obsession
# VALIDATION: This is a smell because AlertEvaluator directly calls Agent.get and
# Agent.update to evaluate thresholds against aggregates and persist alert records,
# independently manipulating the Agent's alerts list without any central owner.
defmodule AlertEvaluator do
  @moduledoc "Checks aggregates against configured thresholds and raises alerts."

  require Logger

  @thresholds %{
    error_rate: 5.0,
    min_unique_users: 1,
    revenue_drop_pct: 20.0
  }

  def check_thresholds(agent) do
    aggregates = Agent.get(agent, fn state -> state.aggregates end)

    alerts =
      aggregates
      |> Map.values()
      |> Enum.flat_map(&evaluate_aggregate/1)

    if alerts != [] do
      Agent.update(agent, fn state ->
        %{state | alerts: state.alerts ++ alerts}
      end)

      Enum.each(alerts, fn a -> Logger.warning("ALERT: #{a.message}") end)
    end

    {:ok, length(alerts)}
  end

  defp evaluate_aggregate(agg) do
    []
    |> maybe_add_alert(agg.error_rate > @thresholds.error_rate,
      "Error rate #{agg.error_rate}% exceeds threshold for #{agg.period}")
    |> maybe_add_alert(agg.unique_users < @thresholds.min_unique_users,
      "No users recorded for #{agg.period}")
  end

  defp maybe_add_alert(alerts, false, _msg), do: alerts

  defp maybe_add_alert(alerts, true, msg) do
    [%{message: msg, raised_at: DateTime.utc_now()} | alerts]
  end
end
# VALIDATION: SMELL END
```
