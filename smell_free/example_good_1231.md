```elixir
defmodule Support.Tickets.EscalationPolicy do
  @moduledoc """
  Evaluates whether a support ticket should be escalated based on
  configurable threshold rules. Rules are pure functions composed
  at call time; no global state is maintained.
  """

  alias Support.Tickets.Ticket

  @type rule :: (Ticket.t() -> boolean())
  @type policy :: %{rules: [rule()], mode: :any | :all}

  @doc """
  Evaluates `policy` against `ticket` and returns whether escalation is warranted.

  Under `:any` mode, escalation triggers if at least one rule matches.
  Under `:all` mode, every rule must match.
  """
  @spec should_escalate?(policy(), Ticket.t()) :: boolean()
  def should_escalate?(%{rules: rules, mode: :any}, %Ticket{} = ticket) do
    Enum.any?(rules, fn rule -> rule.(ticket) end)
  end

  def should_escalate?(%{rules: rules, mode: :all}, %Ticket{} = ticket) do
    Enum.all?(rules, fn rule -> rule.(ticket) end)
  end

  @doc """
  Returns a default escalation policy suitable for standard support queues.
  Escalates on any critical severity, long age, or unacknowledged VIP ticket.
  """
  @spec default_policy() :: policy()
  def default_policy do
    %{
      rules: [
        &critical_severity?/1,
        &overdue?/1,
        &unacknowledged_vip?/1
      ],
      mode: :any
    }
  end

  @doc """
  Builds a policy from a list of named rule atoms and a composition mode.

  Returns `{:ok, policy}` or `{:error, reason}` for unknown rule names.
  """
  @spec build([atom()], :any | :all) :: {:ok, policy()} | {:error, String.t()}
  def build(rule_names, mode) when is_list(rule_names) and mode in [:any, :all] do
    case resolve_rules(rule_names) do
      {:ok, rules} -> {:ok, %{rules: rules, mode: mode}}
      {:error, _} = err -> err
    end
  end

  @doc """
  Rule: returns true when the ticket severity is `:critical`.
  """
  @spec critical_severity?(Ticket.t()) :: boolean()
  def critical_severity?(%Ticket{severity: :critical}), do: true
  def critical_severity?(%Ticket{}), do: false

  @doc """
  Rule: returns true when the ticket has been open longer than 48 hours without resolution.
  """
  @spec overdue?(Ticket.t()) :: boolean()
  def overdue?(%Ticket{opened_at: opened_at, status: status})
      when status in [:open, :pending] do
    age_hours = DateTime.diff(DateTime.utc_now(), opened_at, :hour)
    age_hours > 48
  end

  def overdue?(%Ticket{}), do: false

  @doc """
  Rule: returns true for VIP customer tickets that have not been acknowledged.
  """
  @spec unacknowledged_vip?(Ticket.t()) :: boolean()
  def unacknowledged_vip?(%Ticket{customer_tier: :vip, acknowledged_at: nil}), do: true
  def unacknowledged_vip?(%Ticket{}), do: false

  defp resolve_rules(names) do
    known = %{
      critical_severity: &critical_severity?/1,
      overdue: &overdue?/1,
      unacknowledged_vip: &unacknowledged_vip?/1
    }

    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, acc} ->
      case Map.fetch(known, name) do
        {:ok, rule} -> {:cont, {:ok, acc ++ [rule]}}
        :error -> {:halt, {:error, "unknown rule: #{inspect(name)}"}}
      end
    end)
  end
end
```
