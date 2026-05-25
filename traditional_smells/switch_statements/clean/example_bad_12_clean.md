```elixir
defmodule AlertManager do
  @moduledoc """
  Manages infrastructure and application alerts, routing them through
  appropriate escalation paths based on severity. Integrates with PagerDuty
  and internal Slack-based on-call systems.
  """

  require Logger

  @severities [:critical, :high, :medium, :low]

  def valid_severities, do: @severities







  @doc """
  Returns the number of minutes to wait before auto-escalating an unacknowledged
  alert to the next on-call tier.
  """
  def escalation_delay_minutes(%{severity: severity}) do
    case severity do
      :critical -> 5
      :high -> 15
      :medium -> 60
      :low -> 240
      _ -> 60
    end
  end

  @doc """
  Returns the PagerDuty urgency classification string for the given severity.
  """
  def pagerduty_urgency(%{severity: severity}) do
    case severity do
      :critical -> "high"
      :high -> "high"
      :medium -> "low"
      :low -> "low"
      _ -> "low"
    end
  end

  @doc """
  Returns the hex color code used in Slack and dashboard UI when displaying
  an alert of this severity.
  """
  def alert_color_code(%{severity: severity}) do
    case severity do
      :critical -> "#FF0000"
      :high -> "#FF8800"
      :medium -> "#FFCC00"
      :low -> "#00AA00"
      _ -> "#AAAAAA"
    end
  end



  @doc """
  Fires an alert into the pipeline, computing routing metadata and persisting
  the alert record.
  """
  def fire(%{id: id, title: title, severity: severity} = alert) do
    escalation_min = escalation_delay_minutes(alert)
    urgency = pagerduty_urgency(alert)
    color = alert_color_code(alert)

    alert_record = %{
      id: id,
      title: title,
      severity: severity,
      escalation_at: DateTime.add(DateTime.utc_now(), escalation_min * 60, :second),
      pagerduty_urgency: urgency,
      color: color,
      status: :firing,
      fired_at: DateTime.utc_now()
    }

    notify_on_call(alert_record)
    Logger.warning("[ALERT] #{severity} — #{title} (escalation in #{escalation_min}m)")
    {:ok, alert_record}
  end

  @doc """
  Acknowledges an alert, stopping the escalation clock.
  """
  def acknowledge(%{status: :firing} = alert, acknowledger_id) do
    updated = %{
      alert
      | status: :acknowledged,
        acknowledged_by: acknowledger_id,
        acknowledged_at: DateTime.utc_now()
    }

    Logger.info("Alert #{alert.id} acknowledged by #{acknowledger_id}.")
    {:ok, updated}
  end

  def acknowledge(%{status: status}, _), do: {:error, {:cannot_acknowledge, status}}

  @doc """
  Resolves an active or acknowledged alert, closing the incident.
  """
  def resolve(%{status: status} = alert) when status in [:firing, :acknowledged] do
    resolved = %{alert | status: :resolved, resolved_at: DateTime.utc_now()}
    Logger.info("Alert #{alert.id} resolved.")
    {:ok, resolved}
  end

  def resolve(%{status: status}), do: {:error, {:already_terminal, status}}

  @doc """
  Checks whether auto-escalation is due and, if so, notifies the next tier.
  """
  def maybe_escalate(%{status: :firing, escalation_at: escalation_at} = alert) do
    if DateTime.compare(DateTime.utc_now(), escalation_at) == :gt do
      Logger.warning("Auto-escalating unacknowledged alert #{alert.id} (#{alert.severity}).")
      notify_escalation_tier(alert)
      {:ok, :escalated}
    else
      {:ok, :no_action}
    end
  end

  def maybe_escalate(_alert), do: {:ok, :no_action}



  defp notify_on_call(%{severity: severity} = alert) do
    Logger.debug("Notifying on-call for #{severity} alert #{alert.id}.")
  end

  defp notify_escalation_tier(%{severity: severity} = alert) do
    Logger.debug("Notifying escalation tier for #{severity} alert #{alert.id}.")
  end
end
```
