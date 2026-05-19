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
```
