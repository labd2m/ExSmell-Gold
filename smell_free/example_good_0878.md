```elixir
defmodule MyApp.Alerts.EscalationPolicy do
  @moduledoc """
  Applies an escalation policy to unacknowledged alerts. If an alert has
  not been acknowledged within its configured response window, it is
  escalated to the next tier of on-call responders. Escalation state is
  persisted in the `alert_escalations` table so that the policy survives
  node restarts and the escalation history is queryable.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias MyApp.Alerts.{Alert, AlertEscalation, OncallSchedule}
  alias MyApp.Notifications.Dispatcher

  @escalation_tiers [
    %{tier: 1, label: "primary_oncall", delay_minutes: 15},
    %{tier: 2, label: "secondary_oncall", delay_minutes: 30},
    %{tier: 3, label: "engineering_manager", delay_minutes: 60}
  ]

  @doc """
  Checks all open, unacknowledged alerts and escalates those that have
  exceeded their current tier's response window. Returns the count of
  newly escalated alerts.
  """
  @spec run() :: non_neg_integer()
  def run do
    open_alerts()
    |> Enum.filter(&needs_escalation?/1)
    |> Enum.map(&escalate/1)
    |> Enum.count(&(&1 == :escalated))
  end

  @doc "Returns `true` when `alert` is overdue for its current escalation tier."
  @spec needs_escalation?(Alert.t()) :: boolean()
  def needs_escalation?(%Alert{} = alert) do
    current_tier = current_tier_for(alert)
    delay_minutes = current_tier[:delay_minutes] || 60
    cutoff = DateTime.add(alert.triggered_at, delay_minutes * 60, :second)
    DateTime.compare(DateTime.utc_now(), cutoff) == :gt
  end

  @spec escalate(Alert.t()) :: :escalated | :max_tier_reached | :no_oncall
  defp escalate(%Alert{} = alert) do
    next_tier = next_tier_for(alert)

    case next_tier do
      nil ->
        :max_tier_reached

      tier ->
        responders = OncallSchedule.current_oncall(tier.label)

        if responders == [] do
          :no_oncall
        else
          record_escalation(alert, tier)
          notify_responders(alert, responders, tier)
          :escalated
        end
    end
  end

  @spec open_alerts() :: [Alert.t()]
  defp open_alerts do
    Alert
    |> where([a], a.status == :open and is_nil(a.acknowledged_at))
    |> preload(:escalations)
    |> Repo.all()
  end

  @spec current_tier_for(Alert.t()) :: map() | nil
  defp current_tier_for(alert) do
    max_tier =
      alert.escalations
      |> Enum.map(& &1.tier)
      |> Enum.max(fn -> 0 end)

    Enum.find(@escalation_tiers, fn t -> t.tier == max_tier end)
    |> Kernel.||(List.first(@escalation_tiers))
  end

  @spec next_tier_for(Alert.t()) :: map() | nil
  defp next_tier_for(alert) do
    current = current_tier_for(alert)
    current_tier_num = current[:tier] || 0
    Enum.find(@escalation_tiers, fn t -> t.tier == current_tier_num + 1 end)
  end

  @spec record_escalation(Alert.t(), map()) :: :ok
  defp record_escalation(alert, tier) do
    %AlertEscalation{}
    |> AlertEscalation.changeset(%{
      alert_id: alert.id,
      tier: tier.tier,
      tier_label: tier.label,
      escalated_at: DateTime.utc_now()
    })
    |> Repo.insert()

    :ok
  end

  @spec notify_responders(Alert.t(), [map()], map()) :: :ok
  defp notify_responders(alert, responders, tier) do
    Enum.each(responders, fn responder ->
      Dispatcher.dispatch(%{
        channels: [:sms, :email],
        recipient_email: responder.email,
        recipient_phone: responder.phone,
        subject: "[ESCALATED T#{tier.tier}] #{alert.title}",
        body: "Alert #{alert.id} has been escalated to #{tier.label}.",
        id: "escalation_#{alert.id}_#{tier.tier}"
      })
    end)
  end
end
```
