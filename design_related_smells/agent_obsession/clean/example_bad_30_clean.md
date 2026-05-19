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
    Agent.update(pid, fn state ->
      entry = Map.merge(charge, %{account_id: account_id, inserted_at: DateTime.utc_now()})
      %{state | charges: [entry | state.charges]}
    end)
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
    Agent.get(pid, fn state ->
      state.charges
      |> Enum.filter(&(&1.account_id == account_id))
      |> Enum.reduce(Decimal.new(0), fn charge, acc ->
        Decimal.add(acc, charge.amount)
      end)
    end)
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
    Agent.update(pid, fn state ->
      {to_pay, remaining} =
        Enum.split_with(state.charges, fn c -> c.id == charge_id end)

      updated_paid = state.paid ++ Enum.map(to_pay, &Map.put(&1, :paid_at, DateTime.utc_now()))
      %{state | charges: remaining, paid: updated_paid}
    end)
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
    Agent.get(pid, fn state ->
      overdue =
        Enum.filter(state.charges, fn charge ->
          age_days = Date.diff(Date.utc_today(), DateTime.to_date(charge.inserted_at))
          age_days > 30
        end)

      %{overdue_count: length(overdue), overdue_items: overdue}
    end)
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
