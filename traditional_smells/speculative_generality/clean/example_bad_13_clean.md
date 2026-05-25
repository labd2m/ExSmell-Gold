```elixir
defmodule Notifications.AlertManager do
  @moduledoc """
  Dispatches operational and system alerts to configured recipients.
  Supports multi-channel delivery (email, Slack, PagerDuty) with
  configurable routing rules and acknowledgement tracking.
  """

  alias Notifications.{Alert, AlertChannel, Recipient, AckLog}
  alias Notifications.Repo
  alias Notifications.Adapters.{EmailAdapter, SlackAdapter, PagerDutyAdapter}

  @default_channels  [:email, :slack]
  @ack_timeout_hours 2

  def send_alert(recipients, message, severity \\ :info) do
    channels = determine_channels(severity)

    alert_attrs = %{
      message:    message,
      severity:   severity,
      channels:   channels,
      recipients: Enum.map(recipients, & &1.id),
      status:     :pending,
      sent_at:    DateTime.utc_now()
    }

    case Alert.changeset(%Alert{}, alert_attrs) |> Repo.insert() do
      {:ok, alert} ->
        dispatch_to_channels(alert, recipients, channels)
        {:ok, alert}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def notify_ops_team(event_name, details) do
    recipients = load_ops_recipients()
    message    = format_ops_message(event_name, details)
    send_alert(recipients, message)
  end

  def broadcast_system_event(event_type, payload) do
    recipients = load_all_admins()
    message    = "System event [#{event_type}]: #{inspect(payload)}"
    send_alert(recipients, message)
  end

  def alert_on_threshold(metric_name, value, threshold) do
    if value >= threshold do
      recipients = load_ops_recipients()
      message    = "Threshold breach: #{metric_name} = #{value} (limit: #{threshold})"
      send_alert(recipients, message)
    else
      :ok
    end
  end

  def acknowledge_alert(alert_id, user_id) do
    alert = Repo.get!(Alert, alert_id)

    alert
    |> Alert.changeset(%{status: :acknowledged, acknowledged_by: user_id, acknowledged_at: DateTime.utc_now()})
    |> Repo.update()

    AckLog.record!(:acknowledged, alert_id, user_id)
  end

  def escalate_unacknowledged do
    cutoff = DateTime.add(DateTime.utc_now(), -@ack_timeout_hours * 3600, :second)

    Alert
    |> Repo.all()
    |> Enum.filter(fn a ->
      a.status == :pending and DateTime.compare(a.sent_at, cutoff) == :lt
    end)
    |> Enum.each(fn alert ->
      alert
      |> Alert.changeset(%{status: :escalated, escalated_at: DateTime.utc_now()})
      |> Repo.update()

      recipients = load_escalation_contacts()
      dispatch_to_channels(alert, recipients, [:pagerduty])
    end)
  end

  def alert_history(from_dt, to_dt) do
    Alert
    |> Repo.all()
    |> Enum.filter(fn a ->
      DateTime.compare(a.sent_at, from_dt) in [:gt, :eq] and
        DateTime.compare(a.sent_at, to_dt) in [:lt, :eq]
    end)
    |> Enum.sort_by(& &1.sent_at, {:desc, DateTime})
  end

  def delivery_stats do
    alerts = Repo.all(Alert)

    %{
      total:        length(alerts),
      pending:      Enum.count(alerts, &(&1.status == :pending)),
      acknowledged: Enum.count(alerts, &(&1.status == :acknowledged)),
      escalated:    Enum.count(alerts, &(&1.status == :escalated))
    }
  end


  defp determine_channels(_severity), do: @default_channels

  defp dispatch_to_channels(alert, recipients, channels) do
    Enum.each(channels, fn channel ->
      Enum.each(recipients, fn recipient ->
        case channel do
          :email     -> EmailAdapter.send(recipient.email, alert.message)
          :slack     -> SlackAdapter.post(recipient.slack_handle, alert.message)
          :pagerduty -> PagerDutyAdapter.trigger(recipient.pd_service_key, alert.message)
        end
      end)
    end)
  end

  defp load_ops_recipients do
    Recipient
    |> Repo.all()
    |> Enum.filter(&(&1.group == :ops))
  end

  defp load_all_admins do
    Recipient
    |> Repo.all()
    |> Enum.filter(&(&1.role == :admin))
  end

  defp load_escalation_contacts do
    Recipient
    |> Repo.all()
    |> Enum.filter(&(&1.group == :on_call))
  end

  defp format_ops_message(event_name, details) do
    "[OPS] #{event_name} — #{inspect(details)} at #{DateTime.utc_now()}"
  end
end
```
