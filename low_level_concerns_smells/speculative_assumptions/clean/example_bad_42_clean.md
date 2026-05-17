```elixir
defmodule Support.SlaCalculator do
  @moduledoc """
  Calculates SLA (Service Level Agreement) compliance for support tickets
  based on customer tier and ticket priority.

  SLA thresholds are configured per tier and priority in minutes:
    config :support, :sla_thresholds, %{
      "enterprise" => %{"critical" => 60,   "high" => 240,  "medium" => 1440, "low" => 4320},
      "business"   => %{"critical" => 240,  "high" => 480,  "medium" => 2880, "low" => 8640},
      "starter"    => %{"critical" => 480,  "high" => 1440, "medium" => 5760, "low" => nil}
    }
  """

  require Logger

  @thresholds Application.compile_env(:support, :sla_thresholds, %{})

  @priorities ~w(critical high medium low)
  @tiers      ~w(enterprise business starter)

  def threshold_for(tier, priority) do
    @thresholds
    |> Map.get(tier, %{})
    |> Map.get(priority, 0)
  end

  def breach_status(ticket) do
    %{
      tier:        tier,
      priority:    priority,
      opened_at:   opened_at,
      resolved_at: resolved_at
    } = ticket

    threshold_minutes = threshold_for(tier, priority)
    elapsed_minutes   = elapsed(opened_at, resolved_at)

    cond do
      is_nil(threshold_minutes) ->
        :no_sla

      elapsed_minutes > threshold_minutes ->
        :breached

      elapsed_minutes > threshold_minutes * 0.8 ->
        :at_risk

      true ->
        :within_sla
    end
  end

  def check_open_tickets(tickets) do
    now = DateTime.utc_now()

    Enum.map(tickets, fn ticket ->
      ticket_with_now = Map.put(ticket, :resolved_at, now)
      status          = breach_status(ticket_with_now)
      Map.put(ticket, :sla_status, status)
    end)
  end

  def breach_report(tickets) do
    tickets
    |> Enum.group_by(& &1.priority)
    |> Enum.map(fn {priority, group} ->
      breached = Enum.count(group, &(&1.sla_status == :breached))
      at_risk  = Enum.count(group, &(&1.sla_status == :at_risk))

      %{
        priority: priority,
        total:    length(group),
        breached: breached,
        at_risk:  at_risk
      }
    end)
  end

  defp elapsed(opened_at, nil), do: elapsed(opened_at, DateTime.utc_now())
  defp elapsed(opened_at, resolved_at) do
    DateTime.diff(resolved_at, opened_at, :second) |> div(60)
  end

  def compliance_rate(tickets) do
    total   = length(tickets)
    ok      = Enum.count(tickets, &(&1.sla_status in [:within_sla, :at_risk]))

    if total > 0 do
      Float.round(ok / total * 100.0, 1)
    else
      100.0
    end
  end

  def escalation_candidates(tickets) do
    Enum.filter(tickets, fn t ->
      t.sla_status == :breached and t.priority in ["critical", "high"]
    end)
  end
end
```
