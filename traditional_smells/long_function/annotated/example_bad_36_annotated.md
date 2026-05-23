# Annotated Example — Code Smell: Long Function

## Metadata

- **Smell name:** Long Function
- **Expected smell location:** `Analytics.MetricsEngine.compute_dashboard/2`
- **Affected function(s):** `compute_dashboard/2`
- **Short explanation:** `compute_dashboard/2` handles parameter validation, raw event loading, session aggregation, funnel computation, retention cohort building, revenue KPI calculation, churn-rate derivation, and result caching — all inlined without any helper extraction, producing a function that is deeply complex and hard to maintain.

---

```elixir
defmodule Analytics.MetricsEngine do
  @moduledoc """
  Computes product analytics dashboards including funnel,
  retention, revenue, and churn metrics.
  """

  require Logger

  alias Analytics.{EventStore, SessionStore, RevenueStore, Cache}

  @cache_ttl_sec   300
  @funnel_steps    ["page_view", "signup_start", "signup_complete", "first_purchase"]
  @cohort_weeks    8

  # VALIDATION: SMELL START - Long Function
  # VALIDATION: This is a smell because `compute_dashboard/2` inlines date
  # validation, event fetching, session aggregation, funnel step counting,
  # retention-cohort construction, revenue/ARPU/LTV derivation, churn
  # estimation, and cache writing into a single function body of over
  # 110 lines, with no responsibility delegated to focused helpers.
  def compute_dashboard(workspace_id, params) do
    # 1. Validate and parse date range
    with {:ok, date_from} <- Date.from_iso8601(Map.get(params, "from", "")),
         {:ok, date_to}   <- Date.from_iso8601(Map.get(params, "to", "")) do

      cache_key = "dashboard:#{workspace_id}:#{date_from}:#{date_to}"

      case Cache.get(cache_key) do
        {:ok, cached} ->
          Logger.debug("Dashboard cache hit for #{workspace_id}")
          {:ok, cached}

        _ ->
          Logger.info("Computing dashboard for workspace #{workspace_id} #{date_from}..#{date_to}")

          # 2. Fetch raw events
          events = EventStore.list_for_workspace(workspace_id, date_from, date_to)

          # 3. Session aggregation
          sessions = SessionStore.list_for_workspace(workspace_id, date_from, date_to)

          daily_sessions =
            Enum.group_by(sessions, fn s -> DateTime.to_date(s.started_at) end)
            |> Map.new(fn {date, sess} -> {date, length(sess)} end)

          avg_session_duration =
            if sessions == [] do
              0.0
            else
              total = Enum.sum(Enum.map(sessions, & &1.duration_seconds))
              Float.round(total / length(sessions), 1)
            end

          # 4. Funnel computation
          funnel_counts =
            Enum.map(@funnel_steps, fn step ->
              count =
                events
                |> Enum.filter(&(&1.name == step))
                |> Enum.map(& &1.user_id)
                |> Enum.uniq()
                |> length()

              {step, count}
            end)
            |> Map.new()

          funnel_conversion =
            case {Map.get(funnel_counts, "page_view"), Map.get(funnel_counts, "first_purchase")} do
              {top, bottom} when top > 0 -> Float.round(bottom / top * 100, 2)
              _                          -> 0.0
            end

          # 5. Retention cohorts (weekly)
          cohort_start = Date.add(date_to, -(@cohort_weeks * 7))

          retention_cohorts =
            Enum.map(0..(@cohort_weeks - 1), fn week ->
              week_start = Date.add(cohort_start, week * 7)
              week_end   = Date.add(week_start, 6)

              new_users =
                events
                |> Enum.filter(fn e ->
                  e.name == "signup_complete" and
                    Date.compare(DateTime.to_date(e.occurred_at), week_start) != :lt and
                    Date.compare(DateTime.to_date(e.occurred_at), week_end)   != :gt
                end)
                |> Enum.map(& &1.user_id)
                |> Enum.uniq()

              retained_next_week =
                events
                |> Enum.filter(fn e ->
                  next_start = Date.add(week_end, 1)
                  next_end   = Date.add(next_start, 6)

                  e.user_id in new_users and
                    Date.compare(DateTime.to_date(e.occurred_at), next_start) != :lt and
                    Date.compare(DateTime.to_date(e.occurred_at), next_end)   != :gt
                end)
                |> Enum.map(& &1.user_id)
                |> Enum.uniq()

              rate =
                if length(new_users) > 0,
                  do:   Float.round(length(retained_next_week) / length(new_users) * 100, 1),
                  else: 0.0

              %{week: week + 1, cohort_size: length(new_users), retention_rate: rate}
            end)

          # 6. Revenue KPIs
          revenue_records = RevenueStore.list_for_workspace(workspace_id, date_from, date_to)

          total_revenue = Enum.sum(Enum.map(revenue_records, & &1.amount_cents)) / 100.0
          paying_users  = revenue_records |> Enum.map(& &1.user_id) |> Enum.uniq() |> length()

          arpu =
            if paying_users > 0,
              do:   Float.round(total_revenue / paying_users, 2),
              else: 0.0

          # 7. Churn rate estimate
          active_start = SessionStore.unique_users(workspace_id, Date.add(date_from, -30), date_from)
          active_end   = SessionStore.unique_users(workspace_id, date_from, date_to)

          churned = max(length(active_start) - length(active_end), 0)

          churn_rate =
            if length(active_start) > 0,
              do:   Float.round(churned / length(active_start) * 100, 2),
              else: 0.0

          result = %{
            workspace_id:       workspace_id,
            period:             %{from: date_from, to: date_to},
            sessions:           %{daily: daily_sessions, avg_duration_s: avg_session_duration},
            funnel:             %{counts: funnel_counts, conversion_pct: funnel_conversion},
            retention:          retention_cohorts,
            revenue:            %{total: total_revenue, arpu: arpu},
            churn_rate_pct:     churn_rate,
            computed_at:        DateTime.utc_now()
          }

          Cache.put(cache_key, result, ttl: @cache_ttl_sec)
          {:ok, result}
      end
    else
      _ -> {:error, :invalid_date_format}
    end
  end
  # VALIDATION: SMELL END
end
```
