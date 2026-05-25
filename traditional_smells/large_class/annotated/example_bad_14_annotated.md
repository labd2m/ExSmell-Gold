# Code Smell Annotation

- **Smell name:** Large Class (Large Module)
- **Expected smell location:** The entire `AnalyticsManager` module
- **Affected function(s):** `track_event/3`, `identify_user/2`, `page_view/3`, `flush_event_buffer/0`, `compute_funnel/2`, `retention_cohort/2`, `session_stats/2`, `top_pages/2`, `export_raw_events/2`, `create_dashboard/2`, `add_dashboard_widget/2`
- **Short explanation:** `AnalyticsManager` conflates raw event tracking/ingestion, user identity management, session analytics, funnel computation, cohort retention analysis, page view aggregation, raw event export, and dashboard/widget management. These are completely different analytics concerns that belong in separate modules (e.g., `EventIngestion`, `FunnelAnalyzer`, `CohortAnalyzer`, `SessionAnalyzer`, `DashboardBuilder`).

```elixir
# VALIDATION: SMELL START - Large Class (Large Module)
# VALIDATION: This is a smell because AnalyticsManager handles event
# ingestion/buffering, user identity, session stats, funnel analysis,
# cohort retention, page views, raw export, and dashboard management —
# eight unrelated analytics concerns unified into one oversized module.
defmodule MyApp.AnalyticsManager do
  @moduledoc """
  Unified analytics platform: event tracking, session analysis,
  funnels, retention cohorts, page views, exports, and dashboards.
  """

  require Logger
  import Ecto.Query

  alias MyApp.Repo
  alias MyApp.Analytics.{Event, UserProfile, Session, PageView,
                          FunnelDefinition, Dashboard, DashboardWidget}

  @buffer_name         :analytics_event_buffer
  @flush_threshold     100
  @session_timeout_min 30

  # -------------------------------------------------------------------
  # Event ingestion
  # -------------------------------------------------------------------

  def track_event(user_id, event_name, properties \\ %{}) do
    event = %{
      user_id:    user_id,
      name:       event_name,
      properties: properties,
      timestamp:  System.system_time(:millisecond)
    }

    buffer_event(event)
    :ok
  end

  defp buffer_event(event) do
    current = Process.get(@buffer_name, [])
    updated = [event | current]

    if length(updated) >= @flush_threshold do
      Process.put(@buffer_name, [])
      flush_batch(updated)
    else
      Process.put(@buffer_name, updated)
    end
  end

  def flush_event_buffer do
    events = Process.get(@buffer_name, [])
    Process.put(@buffer_name, [])
    flush_batch(events)
    {:ok, length(events)}
  end

  defp flush_batch([]), do: :ok
  defp flush_batch(events) do
    Repo.insert_all(Event, Enum.map(events, fn e ->
      %{user_id: e.user_id, name: e.name, properties: e.properties,
        occurred_at: DateTime.from_unix!(e.timestamp, :millisecond)}
    end))

    Logger.debug("Flushed #{length(events)} analytics events")
  end

  # -------------------------------------------------------------------
  # User identity
  # -------------------------------------------------------------------

  def identify_user(user_id, traits) when is_map(traits) do
    allowed = Map.take(traits, [:email, :name, :plan, :company, :created_at, :country])

    case Repo.get_by(UserProfile, user_id: user_id) do
      nil ->
        Repo.insert!(%UserProfile{user_id: user_id, traits: allowed})

      profile ->
        merged = Map.merge(profile.traits || %{}, allowed)
        Repo.update!(UserProfile.changeset(profile, %{traits: merged}))
    end

    :ok
  end

  # -------------------------------------------------------------------
  # Page views
  # -------------------------------------------------------------------

  def page_view(user_id, path, referrer \\ nil) do
    Repo.insert!(%PageView{
      user_id:    user_id,
      path:       path,
      referrer:   referrer,
      viewed_at:  DateTime.utc_now()
    })

    :ok
  end

  def top_pages(since, limit \\ 20) do
    from(pv in PageView,
      where: pv.viewed_at >= ^since,
      group_by: pv.path,
      select: %{path: pv.path, views: count(pv.id), unique_users: count(pv.user_id, :distinct)},
      order_by: [desc: count(pv.id)],
      limit: ^limit
    )
    |> Repo.all()
  end

  # -------------------------------------------------------------------
  # Session analysis
  # -------------------------------------------------------------------

  def session_stats(user_id, since) do
    events =
      from(e in Event,
        where: e.user_id == ^user_id and e.occurred_at >= ^since,
        order_by: [asc: e.occurred_at]
      )
      |> Repo.all()

    sessions = group_into_sessions(events, @session_timeout_min)

    avg_duration =
      if Enum.empty?(sessions) do
        0
      else
        total = Enum.sum(Enum.map(sessions, fn s -> s.duration_seconds end))
        div(total, length(sessions))
      end

    %{
      session_count:        length(sessions),
      avg_duration_seconds: avg_duration,
      total_events:         length(events)
    }
  end

  defp group_into_sessions(events, timeout_minutes) do
    timeout_seconds = timeout_minutes * 60

    {sessions, current} =
      Enum.reduce(events, {[], nil}, fn event, {sessions, current} ->
        if current == nil do
          {sessions, %{start: event.occurred_at, last: event.occurred_at, events: [event]}}
        else
          gap = DateTime.diff(event.occurred_at, current.last)

          if gap > timeout_seconds do
            session = finalize_session(current)
            {[session | sessions], %{start: event.occurred_at, last: event.occurred_at, events: [event]}}
          else
            {sessions, %{current | last: event.occurred_at, events: [event | current.events]}}
          end
        end
      end)

    all = if current, do: [finalize_session(current) | sessions], else: sessions
    Enum.reverse(all)
  end

  defp finalize_session(%{start: s, last: l, events: ev}) do
    %{start: s, end: l, duration_seconds: DateTime.diff(l, s), event_count: length(ev)}
  end

  # -------------------------------------------------------------------
  # Funnel analysis
  # -------------------------------------------------------------------

  def compute_funnel(%FunnelDefinition{} = funnel, since) do
    steps = funnel.steps

    user_counts =
      Enum.map(steps, fn step ->
        count =
          from(e in Event,
            where: e.name == ^step and e.occurred_at >= ^since,
            select: count(e.user_id, :distinct)
          )
          |> Repo.one()

        {step, count}
      end)

    [{_, first_count} | rest] = user_counts

    conversion_rates =
      Enum.scan(rest, {first_count, 1.0}, fn {step, count}, {prev_count, _} ->
        rate = if prev_count > 0, do: Float.round(count / prev_count * 100, 1), else: 0.0
        {{step, count}, {count, rate}}
      end)

    %{
      funnel_name: funnel.name,
      steps:       user_counts,
      total_entered: first_count,
      conversion_rates: conversion_rates
    }
  end

  # -------------------------------------------------------------------
  # Retention cohorts
  # -------------------------------------------------------------------

  def retention_cohort(cohort_month, periods \\ 8) do
    cohort_start = Date.new!(cohort_month.year, cohort_month.month, 1)
    cohort_end   = Date.end_of_month(cohort_start)

    cohort_users =
      from(e in Event,
        where: e.occurred_at >= ^DateTime.new!(cohort_start, ~T[00:00:00]) and
               e.occurred_at <= ^DateTime.new!(cohort_end, ~T[23:59:59]),
        select: e.user_id,
        distinct: true
      )
      |> Repo.all()

    base_count = length(cohort_users)

    retention =
      Enum.map(0..(periods - 1), fn offset ->
        period_start = Date.add(cohort_start, offset * 30)
        period_end   = Date.add(period_start, 30)

        retained =
          from(e in Event,
            where: e.user_id in ^cohort_users
              and e.occurred_at >= ^DateTime.new!(period_start, ~T[00:00:00])
              and e.occurred_at <= ^DateTime.new!(period_end, ~T[23:59:59]),
            select: count(e.user_id, :distinct)
          )
          |> Repo.one()

        rate = if base_count > 0, do: Float.round(retained / base_count * 100, 1), else: 0.0
        %{period: offset, users: retained, rate: rate}
      end)

    %{cohort: cohort_month, base_users: base_count, retention: retention}
  end

  # -------------------------------------------------------------------
  # Raw export
  # -------------------------------------------------------------------

  def export_raw_events(user_id, since) do
    from(e in Event,
      where: e.user_id == ^user_id and e.occurred_at >= ^since,
      order_by: [asc: e.occurred_at]
    )
    |> Repo.all()
    |> Enum.map(fn e ->
      "#{e.occurred_at},#{e.name},#{Jason.encode!(e.properties)}\n"
    end)
    |> Enum.join()
  end

  # -------------------------------------------------------------------
  # Dashboard management
  # -------------------------------------------------------------------

  def create_dashboard(owner_id, attrs) do
    Repo.insert(%Dashboard{
      owner_id: owner_id,
      name:     attrs[:name],
      layout:   attrs[:layout] || :grid,
      shared:   attrs[:shared] || false
    })
  end

  def add_dashboard_widget(%Dashboard{} = dashboard, widget_attrs) do
    Repo.insert(%DashboardWidget{
      dashboard_id: dashboard.id,
      widget_type:  widget_attrs[:type],
      title:        widget_attrs[:title],
      config:       widget_attrs[:config] || %{},
      position:     widget_attrs[:position] || %{x: 0, y: 0, w: 4, h: 3}
    })
  end

  def list_dashboards(owner_id) do
    from(d in Dashboard, where: d.owner_id == ^owner_id or d.shared == true)
    |> Repo.all()
  end
end
# VALIDATION: SMELL END
```
