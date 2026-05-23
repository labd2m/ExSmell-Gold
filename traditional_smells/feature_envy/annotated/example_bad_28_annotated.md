# Annotated Example – Bad Code (Feature Envy)

## Metadata

| Field | Value |
|---|---|
| **Smell** | Feature Envy |
| **Expected Smell Location** | `Analytics.RetentionReport.build_cohort_row/1` |
| **Affected Function(s)** | `build_cohort_row/1` |
| **Explanation** | `build_cohort_row/1` lives in `Analytics.RetentionReport` but exclusively uses `Analytics.UserEngagement` — calling `get!/1`, `days_since_signup/1`, `session_count/1`, `feature_adoption_rate/1`, `churned?/1`, and reading struct fields directly. The function is more interested in `UserEngagement` than in the report module and belongs there. |

```elixir
defmodule Analytics.UserEngagement do
  @moduledoc "Represents aggregated engagement metrics for a single user."

  defstruct [
    :id,
    :user_id,
    :cohort_month,
    :signup_at,
    :last_active_at,
    :total_sessions,
    :features_used,
    :total_features,
    :plan,
    :churned_at,
    :nps_score
  ]

  def get!(id) do
    %__MODULE__{
      id: id,
      user_id: "USR-7701",
      cohort_month: "2024-01",
      signup_at: ~U[2024-01-15 00:00:00Z],
      last_active_at: ~U[2024-03-10 10:00:00Z],
      total_sessions: 42,
      features_used: 7,
      total_features: 12,
      plan: :growth,
      churned_at: nil,
      nps_score: 8
    }
  end

  def days_since_signup(%__MODULE__{signup_at: signed_up}) do
    DateTime.diff(DateTime.utc_now(), signed_up, :day)
  end

  def session_count(%__MODULE__{total_sessions: s}), do: s

  def feature_adoption_rate(%__MODULE__{features_used: used, total_features: total})
      when total > 0 do
    Float.round(used / total * 100, 1)
  end
  def feature_adoption_rate(_), do: 0.0

  def churned?(%__MODULE__{churned_at: nil}), do: false
  def churned?(_), do: true

  def days_to_churn(%__MODULE__{signup_at: s, churned_at: c}) when not is_nil(c) do
    DateTime.diff(c, s, :day)
  end
  def days_to_churn(_), do: nil

  def plan_label(%__MODULE__{plan: :starter}),    do: "Starter"
  def plan_label(%__MODULE__{plan: :growth}),     do: "Growth"
  def plan_label(%__MODULE__{plan: :enterprise}), do: "Enterprise"
  def plan_label(_),                              do: "Unknown"
end

defmodule Analytics.RetentionReport do
  @moduledoc """
  Builds cohort-based retention reports for product and growth analytics.
  Each row represents a single user's engagement trajectory.
  """

  alias Analytics.UserEngagement
  require Logger

  @doc """
  Generates a retention report for the given list of engagement record IDs.
  """
  def generate(engagement_ids) do
    rows = Enum.map(engagement_ids, &build_cohort_row/1)

    retained = Enum.count(rows, &(not &1.churned))
    avg_sessions = rows |> Enum.map(& &1.sessions) |> average()

    %{
      rows:         rows,
      total:        length(rows),
      retained:     retained,
      churned:      length(rows) - retained,
      avg_sessions: Float.round(avg_sessions, 1),
      generated_at: DateTime.utc_now()
    }
  end

  # VALIDATION: SMELL START - Feature Envy
  # VALIDATION: This is a smell because `build_cohort_row/1` belongs to
  # VALIDATION: `Analytics.RetentionReport` but every operation goes through
  # VALIDATION: `Analytics.UserEngagement`: it calls `UserEngagement.get!/1`,
  # VALIDATION: `UserEngagement.days_since_signup/1`, `UserEngagement.session_count/1`,
  # VALIDATION: `UserEngagement.feature_adoption_rate/1`, and `UserEngagement.churned?/1`.
  # VALIDATION: The function touches nothing from its own module and should live
  # VALIDATION: inside `UserEngagement`.
  defp build_cohort_row(engagement_id) do
    record   = UserEngagement.get!(engagement_id)
    days     = UserEngagement.days_since_signup(record)
    sessions = UserEngagement.session_count(record)
    adoption = UserEngagement.feature_adoption_rate(record)
    churned  = UserEngagement.churned?(record)

    %{
      user_id:        record.user_id,
      cohort_month:   record.cohort_month,
      plan:           record.plan,
      days_active:    days,
      sessions:       sessions,
      adoption_pct:   adoption,
      churned:        churned,
      nps:            record.nps_score
    }
  end
  # VALIDATION: SMELL END

  defp average([]), do: 0.0
  defp average(list), do: Enum.sum(list) / length(list)
end
```
