```elixir
defmodule SubscriptionLedger do
  @moduledoc """
  Agent-backed store of customer subscription records.
  """

  def start_link do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  def create(pid, customer_id, plan) do
    sub_id = :crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)

    record = %{
      id: sub_id,
      customer_id: customer_id,
      plan: plan,
      status: :active,
      current_period_start: Date.utc_today(),
      current_period_end: Date.utc_today() |> Date.add(30),
      amount_due: plan_price(plan),
      invoices: []
    }

    Agent.update(pid, fn subs -> Map.put(subs, sub_id, record) end)
    {:ok, sub_id}
  end

  def fetch(pid, sub_id) do
    Agent.get(pid, fn subs -> Map.fetch(subs, sub_id) end)
  end

  def all_active(pid) do
    Agent.get(pid, fn subs ->
      subs |> Map.values() |> Enum.filter(&(&1.status == :active))
    end)
  end

  defp plan_price(:basic), do: 9_99
  defp plan_price(:pro), do: 29_99
  defp plan_price(:enterprise), do: 99_99
  defp plan_price(_), do: 0
end

defmodule BillingCycleRunner do
  @moduledoc """
  Advances billing periods and triggers invoice generation.
  """

  def run_cycle(pid, sub_id) do
    Agent.get_and_update(pid, fn subs ->
      case Map.fetch(subs, sub_id) do
        {:ok, sub} when sub.status == :active ->
          updated =
            %{
              sub
              | current_period_start: Date.add(sub.current_period_start, 30),
                current_period_end: Date.add(sub.current_period_end, 30)
            }

          {{:ok, updated}, Map.put(subs, sub_id, updated)}

        {:ok, sub} ->
          {{:skip, sub.status}, subs}

        :error ->
          {:not_found, subs}
      end
    end)
  end

  def run_all(pid) do
    Agent.get(pid, fn subs -> Map.keys(subs) end)
    |> Enum.map(&run_cycle(pid, &1))
  end
end

defmodule InvoiceBuilder do
  @moduledoc """
  Generates invoice records for a billing cycle.
  """

  def generate(pid, sub_id) do
    invoice_id = :crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)

    Agent.get_and_update(pid, fn subs ->
      case Map.fetch(subs, sub_id) do
        {:ok, sub} ->
          invoice = %{
            id: invoice_id,
            amount: sub.amount_due,
            period_start: sub.current_period_start,
            period_end: sub.current_period_end,
            issued_at: DateTime.utc_now(),
            paid: false
          }

          updated = %{sub | invoices: [invoice | sub.invoices]}
          {{:ok, invoice}, Map.put(subs, sub_id, updated)}

        :error ->
          {:not_found, subs}
      end
    end)
  end

  def unpaid_invoices(pid, sub_id) do
    Agent.get(pid, fn subs ->
      subs
      |> Map.get(sub_id, %{invoices: []})
      |> Map.get(:invoices, [])
      |> Enum.reject(& &1.paid)
    end)
  end
end

defmodule DunningService do
  @moduledoc """
  Handles overdue subscriptions and triggers payment reminders.
  """

  def mark_overdue(pid, sub_id) do
    Agent.update(pid, fn subs ->
      case Map.fetch(subs, sub_id) do
        {:ok, sub} when sub.status == :active ->
          Map.put(subs, sub_id, %{sub | status: :past_due})

        _ ->
          subs
      end
    end)
  end

  def cancel(pid, sub_id) do
    Agent.update(pid, fn subs ->
      Map.update(subs, sub_id, %{}, fn sub -> %{sub | status: :cancelled} end)
    end)
  end

  def overdue_subscriptions(pid) do
    Agent.get(pid, fn subs ->
      subs |> Map.values() |> Enum.filter(&(&1.status == :past_due))
    end)
  end
end
```
