# Code Smell: Agent Obsession

## Metadata

- **Smell name:** Agent Obsession
- **Expected smell location:** Modules `BillingAccumulator`, `BillingReport`, `BillingReconciler`, and `BillingAuditor`
- **Affected functions:** `BillingAccumulator.add_charge/3`, `BillingReport.monthly_total/2`, `BillingReconciler.mark_paid/2`, `BillingAuditor.audit_unpaid/1`
- **Short explanation:** Four modules all interact directly with the same Agent holding billing state. No single module is responsible for the data contract, and the internal structure of the billing state is duplicated across all four.

---

```elixir
defmodule Billing.BillingAccumulator do
  @moduledoc """
  Accumulates charges for a billing period.
  """

  def start_link() do
    Agent.start_link(fn ->
      %{charges: [], paid: [], period: Date.utc_today()}
    end)
  end

  def add_charge(pid, account_id, charge) do
    # VALIDATION: SMELL START - Agent Obsession
    # VALIDATION: This is a smell because BillingAccumulator directly calls Agent.update/2
    # to mutate billing state. Other modules also interact with the same agent directly,
    # spreading the ownership of state management.
    Agent.update(pid, fn state ->
      entry = Map.merge(charge, %{account_id: account_id, inserted_at: DateTime.utc_now()})
      %{state | charges: [entry | state.charges]}
    end)
    # VALIDATION: SMELL END
  end

  def clear_period(pid) do
    Agent.update(pid, fn state ->
      %{state | charges: [], paid: [], period: Date.utc_today()}
    end)
  end
end

defmodule Billing.BillingReport do
  @moduledoc """
  Generates monthly billing reports per account.
  """

  def monthly_total(pid, account_id) do
    # VALIDATION: SMELL START - Agent Obsession
    # VALIDATION: This is a smell because BillingReport directly calls Agent.get/2,
    # independently knowing the structure of the charges list stored in the agent.
    Agent.get(pid, fn state ->
      state.charges
      |> Enum.filter(&(&1.account_id == account_id))
      |> Enum.reduce(Decimal.new(0), fn charge, acc ->
        Decimal.add(acc, charge.amount)
      end)
    end)
    # VALIDATION: SMELL END
  end

  def summary_by_account(pid) do
    Agent.get(pid, fn state ->
      state.charges
      |> Enum.group_by(& &1.account_id)
      |> Enum.map(fn {account_id, charges} ->
        total = Enum.reduce(charges, Decimal.new(0), &Decimal.add(&2, &1.amount))
        {account_id, total}
      end)
      |> Map.new()
    end)
  end
end

defmodule Billing.BillingReconciler do
  @moduledoc """
  Marks charges as paid and reconciles accounts.
  """

  def mark_paid(pid, charge_id) do
    # VALIDATION: SMELL START - Agent Obsession
    # VALIDATION: This is a smell because BillingReconciler directly manipulates Agent state,
    # adding a third point of direct interaction with the same agent store.
    Agent.update(pid, fn state ->
      {to_pay, remaining} =
        Enum.split_with(state.charges, fn c -> c.id == charge_id end)

      updated_paid = state.paid ++ Enum.map(to_pay, &Map.put(&1, :paid_at, DateTime.utc_now()))
      %{state | charges: remaining, paid: updated_paid}
    end)
    # VALIDATION: SMELL END
  end

  def reconcile_account(pid, account_id) do
    Agent.get(pid, fn state ->
      unpaid = Enum.filter(state.charges, &(&1.account_id == account_id))
      paid = Enum.filter(state.paid, &(&1.account_id == account_id))
      %{unpaid_count: length(unpaid), paid_count: length(paid)}
    end)
  end
end

defmodule Billing.BillingAuditor do
  @moduledoc """
  Audits billing state for compliance and anomalies.
  """

  def audit_unpaid(pid) do
    # VALIDATION: SMELL START - Agent Obsession
    # VALIDATION: This is a smell because BillingAuditor directly reads Agent state,
    # making it a fourth module that knows and depends on the internal billing state structure.
    Agent.get(pid, fn state ->
      overdue =
        Enum.filter(state.charges, fn charge ->
          age_days = Date.diff(Date.utc_today(), DateTime.to_date(charge.inserted_at))
          age_days > 30
        end)

      %{overdue_count: length(overdue), overdue_items: overdue}
    end)
    # VALIDATION: SMELL END
  end

  def audit_duplicates(pid) do
    Agent.get(pid, fn state ->
      state.charges
      |> Enum.group_by(&{&1.account_id, &1.description, &1.amount})
      |> Enum.filter(fn {_key, charges} -> length(charges) > 1 end)
      |> Enum.map(fn {key, charges} -> {key, length(charges)} end)
    end)
  end
end
```
