```elixir
defmodule MyApp.Metrics.SLAMonitor do
  @moduledoc """
  Monitors service-level agreement compliance by comparing measured
  latency and error-rate metrics against configured thresholds. Breaches
  are recorded in the `sla_breaches` table and broadcast over PubSub so
  that on-call alerting systems receive them without polling.

  The monitor runs on a configurable evaluation interval and computes
  compliance windows from pre-aggregated metric buckets already present
  in ETS via `MyApp.Analytics.SessionAggregator` or equivalent.
  """

  use GenServer

  require Logger

  alias MyApp.Repo
  alias MyApp.Metrics.{SLABreach, SLADefinition}

  import Ecto.Query, warn: false

  @pubsub MyApp.PubSub
  @topic "sla:breaches"
  @eval_interval_ms 60_000

  @type sla_name :: String.t()
  @type breach_severity :: :warning | :critical

  @doc "Starts the SLA monitor."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Subscribes the caller to SLA breach events."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(@pubsub, @topic)

  @doc "Returns all active SLA breaches currently open."
  @spec active_breaches() :: [SLABreach.t()]
  def active_breaches do
    SLABreach
    |> where([b], is_nil(b.resolved_at))
    |> order_by([b], desc: b.detected_at)
    |> Repo.all()
  end

  @impl GenServer
  def init(opts) do
    interval = Keyword.get(opts, :eval_interval_ms, @eval_interval_ms)
    schedule_evaluation(interval)
    {:ok, %{interval_ms: interval}}
  end

  @impl GenServer
  def handle_info(:evaluate, state) do
    evaluate_all_slas()
    schedule_evaluation(state.interval_ms)
    {:noreply, state}
  end

  @spec evaluate_all_slas() :: :ok
  defp evaluate_all_slas do
    SLADefinition
    |> where([d], d.active == true)
    |> Repo.all()
    |> Enum.each(&evaluate_sla/1)
  end

  @spec evaluate_sla(SLADefinition.t()) :: :ok
  defp evaluate_sla(definition) do
    measurement = fetch_measurement(definition)

    cond do
      exceeds_threshold?(measurement, definition.critical_threshold) ->
        record_breach(definition, measurement, :critical)

      exceeds_threshold?(measurement, definition.warning_threshold) ->
        record_breach(definition, measurement, :warning)

      true ->
        resolve_open_breach(definition)
    end

    :ok
  end

  @spec exceeds_threshold?(float(), float() | nil) :: boolean()
  defp exceeds_threshold?(_measurement, nil), do: false
  defp exceeds_threshold?(measurement, threshold), do: measurement > threshold

  @spec fetch_measurement(SLADefinition.t()) :: float()
  defp fetch_measurement(definition) do
    apply(MyApp.Metrics.Collectors, definition.collector_function, [definition.window_minutes])
  rescue
    _ -> 0.0
  end

  @spec record_breach(SLADefinition.t(), float(), breach_severity()) :: :ok
  defp record_breach(definition, measurement, severity) do
    result =
      %SLABreach{}
      |> SLABreach.changeset(%{
        sla_definition_id: definition.id,
        sla_name: definition.name,
        measured_value: measurement,
        severity: severity,
        detected_at: DateTime.utc_now()
      })
      |> Repo.insert(
        on_conflict: {:replace, [:measured_value, :severity, :updated_at]},
        conflict_target: [:sla_definition_id, :resolved_at]
      )

    case result do
      {:ok, breach} ->
        Logger.warning("sla_breach_detected", sla: definition.name, severity: severity)
        Phoenix.PubSub.broadcast(@pubsub, @topic, {:sla_breach, breach})

      {:error, reason} ->
        Logger.error("sla_breach_record_failed", reason: inspect(reason))
    end

    :ok
  end

  @spec resolve_open_breach(SLADefinition.t()) :: :ok
  defp resolve_open_breach(definition) do
    {count, _} =
      SLABreach
      |> where([b], b.sla_definition_id == ^definition.id and is_nil(b.resolved_at))
      |> Repo.update_all(set: [resolved_at: DateTime.utc_now()])

    if count > 0 do
      Logger.info("sla_breach_resolved", sla: definition.name)
      Phoenix.PubSub.broadcast(@pubsub, @topic, {:sla_resolved, definition.name})
    end

    :ok
  end

  @spec schedule_evaluation(pos_integer()) :: reference()
  defp schedule_evaluation(interval_ms),
    do: Process.send_after(self(), :evaluate, interval_ms)
end
```
