```elixir
# ── file: lib/compliance/checker.ex ─────────────────────────────────────────

defmodule Compliance.Checker do
  @moduledoc """
  Runs compliance checks against GDPR, PCI-DSS, and internal data policies.
  Defined in `lib/compliance/checker.ex`.
  """

  alias Compliance.{Rules, ViolationStore, ReportRenderer, DataMap}

  @ruleset_versions %{gdpr: "2018-05-25", pci: "v4.0", internal: "2024-01"}

  @type entity_type :: :user | :transaction | :stored_card | :audit_log
  @type check_result :: %{
    passed: [String.t()],
    violations: [map()],
    warnings: [String.t()],
    checked_at: DateTime.t()
  }

  @doc """
  Run the full applicable compliance suite against an entity.
  `entity_type` selects which rule categories to apply.
  Returns a structured result map with passed checks and violations.
  """
  @spec run(entity_type(), map()) :: {:ok, check_result()} | {:error, String.t()}
  def run(entity_type, entity) do
    rule_sets = Rules.applicable_for(entity_type)

    {passed, violations, warnings} =
      Enum.reduce(rule_sets, {[], [], []}, fn rule, {p, v, w} ->
        case Rules.evaluate(rule, entity) do
          :pass ->
            {[rule.id | p], v, w}

          {:violation, detail} ->
            {p, [%{rule_id: rule.id, detail: detail, severity: rule.severity} | v], w}

          {:warning, msg} ->
            {p, v, [msg | w]}
        end
      end)

    result = %{
      passed: Enum.reverse(passed),
      violations: Enum.reverse(violations),
      warnings: Enum.reverse(warnings),
      checked_at: DateTime.utc_now()
    }

    if violations != [] do
      ViolationStore.record(entity_type, entity, violations)
    end

    {:ok, result}
  end

  @doc "Check an entity against GDPR-specific rules only."
  @spec check_gdpr(map()) :: {:ok, check_result()} | {:error, String.t()}
  def check_gdpr(entity) do
    rules = Rules.by_category(:gdpr)

    violations =
      Enum.flat_map(rules, fn rule ->
        case Rules.evaluate(rule, entity) do
          {:violation, detail} -> [%{rule_id: rule.id, detail: detail, severity: rule.severity}]
          _ -> []
        end
      end)

    {:ok,
     %{
       passed: length(rules) - length(violations),
       violations: violations,
       ruleset_version: @ruleset_versions[:gdpr],
       checked_at: DateTime.utc_now()
     }}
  end

  @doc "Check a transaction or stored card entity against PCI-DSS rules."
  @spec check_pci(map()) :: {:ok, check_result()} | {:error, String.t()}
  def check_pci(%{type: t} = entity) when t in [:transaction, :stored_card] do
    rules = Rules.by_category(:pci)

    violations =
      Enum.flat_map(rules, fn rule ->
        case Rules.evaluate(rule, entity) do
          {:violation, detail} ->
            [%{rule_id: rule.id, detail: detail, severity: rule.severity}]

          _ ->
            []
        end
      end)

    {:ok,
     %{
       violations: violations,
       compliant: violations == [],
       ruleset_version: @ruleset_versions[:pci],
       checked_at: DateTime.utc_now()
     }}
  end

  def check_pci(%{type: t}) do
    {:error, "PCI checks not applicable for entity type: #{t}"}
  end

  @doc "Return all open violations for a given entity ID."
  @spec violations(String.t()) :: {:ok, [map()]} | {:error, String.t()}
  def violations(entity_id) do
    case ViolationStore.fetch_open(entity_id) do
      {:ok, vs} -> {:ok, Enum.sort_by(vs, &{severity_rank(&1.severity), &1.detected_at})}
      :not_found -> {:ok, []}
    end
  end

  @doc "Render a compliance report for an entity over a given time range."
  @spec generate_report(String.t(), keyword()) :: {:ok, binary()} | {:error, String.t()}
  def generate_report(entity_id, opts \\ []) do
    format = Keyword.get(opts, :format, :pdf)
    from = Keyword.get(opts, :from, DateTime.add(DateTime.utc_now(), -86_400 * 30, :second))
    to = Keyword.get(opts, :to, DateTime.utc_now())

    with {:ok, vs} <- ViolationStore.query(entity_id: entity_id, from: from, to: to) do
      ReportRenderer.render(vs, format: format, entity_id: entity_id, period: {from, to})
    end
  end

  defp severity_rank(:critical), do: 0
  defp severity_rank(:high), do: 1
  defp severity_rank(:medium), do: 2
  defp severity_rank(:low), do: 3
  defp severity_rank(_), do: 4
end


# ── file: lib/compliance/checker_remediation.ex  

defmodule Compliance.Checker do
  @moduledoc """
  Remediation workflow management for open compliance violations.
  Was intended to be `Compliance.Checker.Remediation` but was accidentally
  given the same module name as the core compliance checker.
  """

  alias Compliance.{ViolationStore, RemediationStore, NotificationBus}

  @doc "Open a remediation task for a specific violation."
  @spec open_remediation(map()) :: {:ok, map()} | {:error, String.t()}
  def open_remediation(%{rule_id: rule_id, entity_id: entity_id} = violation) do
    task = %{
      id: generate_id(),
      rule_id: rule_id,
      entity_id: entity_id,
      violation: violation,
      status: :open,
      due_date: Date.add(Date.utc_today(), 30),
      assigned_to: nil,
      created_at: DateTime.utc_now()
    }

    with {:ok, saved} <- RemediationStore.save(task) do
      NotificationBus.publish(:remediation_opened, saved)
      {:ok, saved}
    end
  end

  @doc "Close a remediation task with a resolution note."
  @spec close_remediation(String.t(), String.t()) :: :ok | {:error, String.t()}
  def close_remediation(task_id, resolution_note) do
    with {:ok, task} <- RemediationStore.fetch(task_id),
         :ok <- check_open(task) do
      RemediationStore.update(task_id, %{
        status: :closed,
        resolution_note: resolution_note,
        closed_at: DateTime.utc_now()
      })

      ViolationStore.mark_resolved(task.violation.id)
    end
  end

  @doc "Return all open remediation tasks past their due date."
  @spec overdue_tasks() :: [map()]
  def overdue_tasks do
    today = Date.utc_today()

    RemediationStore.all(status: :open)
    |> Enum.filter(&(Date.compare(&1.due_date, today) == :lt))
    |> Enum.sort_by(& &1.due_date)
  end

  defp check_open(%{status: :open}), do: :ok
  defp check_open(%{status: s}), do: {:error, "Remediation task is not open (status: #{s})"}

  defp generate_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
end

```
