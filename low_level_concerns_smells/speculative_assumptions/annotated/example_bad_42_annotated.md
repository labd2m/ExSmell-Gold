# Annotated Example — Speculative Assumptions

## Metadata

- **Smell name:** Speculative Assumptions
- **Expected smell location:** `Support.SlaCalculator.threshold_for/2`, around the nested map access chain
- **Affected function(s):** `threshold_for/2`
- **Short explanation:** The function accesses a nested configuration map using successive `Map.get/3` calls with `%{}` as the default at each level. If the `priority` or `tier` key is missing from the config, an intermediate `Map.get/3` returns `%{}`, and the next level call silently returns `0` (the final default). The function always returns an integer — either correct or `0` — so SLA breach detection silently treats missing config as a zero-minute SLA, flagging everything as breached or, conversely, never flagging breaches depending on the comparison direction.

---

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

  # VALIDATION: SMELL START - Speculative Assumptions
  # VALIDATION: This is a smell because the function accesses the nested thresholds
  # VALIDATION: map with two consecutive Map.get/3 calls, each using a default of %{}
  # VALIDATION: or 0 respectively. If the tier key ("enterprise", "business", etc.)
  # VALIDATION: is missing from the config — due to a misconfiguration, a new tier
  # VALIDATION: being added without updating the config, or a typo in the tier string
  # VALIDATION: — the first Map.get returns %{}, and the second Map.get on that empty
  # VALIDATION: map returns 0. The function then uses 0 minutes as the SLA threshold,
  # VALIDATION: causing every ticket to appear as breached (since elapsed_minutes > 0).
  # VALIDATION: No crash or error is raised; the SLA breach flag is silently wrong,
  # VALIDATION: creating a false picture of system health.
  def threshold_for(tier, priority) do
    @thresholds
    |> Map.get(tier, %{})
    |> Map.get(priority, 0)
  end
  # VALIDATION: SMELL END

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
