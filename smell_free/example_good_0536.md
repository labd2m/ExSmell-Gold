```elixir
defmodule Support.EscalationPolicy do
  @moduledoc """
  Evaluates support ticket escalation rules and returns the target team and
  priority for a given ticket. Escalation decisions depend on SLA breach
  status, customer tier, ticket age, and unresolved reply count. All logic
  is pure and expressed as an ordered rule list; the first matching rule wins.
  """

  @type customer_tier :: :free | :starter | :growth | :enterprise
  @type ticket_context :: %{
          status: atom(),
          customer_tier: customer_tier(),
          age_hours: non_neg_integer(),
          unresolved_replies: non_neg_integer(),
          sla_breached: boolean(),
          assigned_team: String.t() | nil
        }

  @type escalation :: %{
          team: String.t(),
          priority: :low | :normal | :high | :urgent,
          reason: String.t()
        }

  @escalation_rules [
    {
      "sla_breach_enterprise",
      fn ctx -> ctx.sla_breached and ctx.customer_tier == :enterprise end,
      %{team: "enterprise_support", priority: :urgent, reason: "SLA breach for Enterprise customer"}
    },
    {
      "sla_breach_growth",
      fn ctx -> ctx.sla_breached and ctx.customer_tier == :growth end,
      %{team: "priority_support", priority: :high, reason: "SLA breach for Growth customer"}
    },
    {
      "old_unresolved_enterprise",
      fn ctx -> ctx.age_hours > 24 and ctx.customer_tier == :enterprise and ctx.status != :closed end,
      %{team: "enterprise_support", priority: :high, reason: "Open Enterprise ticket > 24h"}
    },
    {
      "high_reply_count",
      fn ctx -> ctx.unresolved_replies >= 5 end,
      %{team: "tier2_support", priority: :high, reason: "High unresolved reply count"}
    },
    {
      "old_unresolved_any",
      fn ctx -> ctx.age_hours > 72 and ctx.status not in [:closed, :resolved] end,
      %{team: "tier2_support", priority: :normal, reason: "Ticket unresolved > 72h"}
    }
  ]

  @doc """
  Evaluates escalation rules against `ctx`. Returns the first matching
  escalation decision or `{:ok, :no_escalation}` when no rule fires.
  """
  @spec evaluate(ticket_context()) :: {:ok, escalation()} | {:ok, :no_escalation}
  def evaluate(%{} = ctx) do
    result =
      Enum.find_value(@escalation_rules, fn {_name, predicate, escalation} ->
        if predicate.(ctx), do: escalation, else: nil
      end)

    case result do
      nil -> {:ok, :no_escalation}
      escalation -> {:ok, escalation}
    end
  end

  @doc "Returns all rule names that would fire for `ctx`."
  @spec matching_rules(ticket_context()) :: [String.t()]
  def matching_rules(%{} = ctx) do
    @escalation_rules
    |> Enum.filter(fn {_name, predicate, _esc} -> predicate.(ctx) end)
    |> Enum.map(fn {name, _predicate, _esc} -> name end)
  end

  @doc "Returns the names of all registered escalation rules."
  @spec rule_names() :: [String.t()]
  def rule_names, do: Enum.map(@escalation_rules, fn {name, _, _} -> name end)
end
```
