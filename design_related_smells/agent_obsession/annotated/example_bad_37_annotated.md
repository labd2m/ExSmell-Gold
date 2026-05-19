# Annotated Example – Bad Code

- **Smell name:** Agent Obsession
- **Expected smell location:** Modules `BillingProcessor`, `InvoiceAuditor`, `PaymentGateway`, and `BillingReporter`
- **Affected functions:** `BillingProcessor.apply_discount/2`, `InvoiceAuditor.flag_overdue/2`, `PaymentGateway.record_charge/3`, `BillingReporter.summarize/1`
- **Short explanation:** Direct `Agent` calls are scattered across four unrelated modules. Each module reads or mutates the shared billing state independently, without going through a single owner module. This spreads the responsibility for the Agent's data format across the whole system.

```elixir
defmodule BillingState do
  @moduledoc """
  Starts the shared billing Agent that holds the current billing cycle state.
  """

  def start_link(initial \\ %{invoices: [], charges: [], discounts: [], flags: []}) do
    Agent.start_link(fn -> initial end, name: __MODULE__)
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end
end

# VALIDATION: SMELL START - Agent Obsession
# VALIDATION: This is a smell because BillingProcessor directly calls Agent.get/update
# on the shared billing Agent instead of delegating to a dedicated owner module.
defmodule BillingProcessor do
  @moduledoc """
  Applies discounts and pricing rules to invoices in the current billing cycle.
  """

  require Logger

  @standard_discount 0.10
  @bulk_discount 0.20
  @bulk_threshold 5

  def apply_discount(agent, customer_id) do
    invoices = Agent.get(agent, fn state -> state.invoices end)

    customer_invoices =
      Enum.filter(invoices, fn inv -> inv.customer_id == customer_id end)

    rate =
      if length(customer_invoices) >= @bulk_threshold,
        do: @bulk_discount,
        else: @standard_discount

    discounted =
      Enum.map(customer_invoices, fn inv ->
        %{inv | total: Float.round(inv.total * (1 - rate), 2)}
      end)

    Agent.update(agent, fn state ->
      updated_invoices =
        Enum.map(state.invoices, fn inv ->
          case Enum.find(discounted, &(&1.id == inv.id)) do
            nil -> inv
            updated -> updated
          end
        end)

      discount_entry = %{
        customer_id: customer_id,
        rate: rate,
        applied_at: DateTime.utc_now()
      }

      %{state | invoices: updated_invoices, discounts: [discount_entry | state.discounts]}
    end)

    Logger.info("Applied #{rate * 100}% discount to customer #{customer_id}")
    :ok
  end
end
# VALIDATION: SMELL END

defmodule InvoiceAuditor do
  @moduledoc """
  Audits invoices and flags those that are overdue based on due date.
  """

  require Logger

  @grace_period_days 3

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because InvoiceAuditor also directly calls Agent.update
  # on the same shared Agent, further spreading ownership of the Agent's internal state.
  def flag_overdue(agent, reference_date \\ Date.utc_today()) do
    cutoff = Date.add(reference_date, -@grace_period_days)

    Agent.update(agent, fn state ->
      {flagged, clean} =
        Enum.split_with(state.invoices, fn inv ->
          not inv.paid and Date.compare(inv.due_date, cutoff) == :lt
        end)

      flag_entries =
        Enum.map(flagged, fn inv ->
          %{invoice_id: inv.id, customer_id: inv.customer_id, overdue_since: inv.due_date}
        end)

      Logger.warning("Flagging #{length(flagged)} overdue invoices")

      %{state | invoices: clean ++ flagged, flags: state.flags ++ flag_entries}
    end)

    :ok
  end
  # VALIDATION: SMELL END
end

defmodule PaymentGateway do
  @moduledoc """
  Records charges after a payment provider confirms a transaction.
  """

  require Logger

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because PaymentGateway directly mutates the shared Agent
  # state by appending a charge record, bypassing any centralised data contract.
  def record_charge(agent, invoice_id, amount) when is_float(amount) and amount > 0 do
    Agent.update(agent, fn state ->
      charge = %{
        id: :crypto.strong_rand_bytes(8) |> Base.encode16(),
        invoice_id: invoice_id,
        amount: amount,
        recorded_at: DateTime.utc_now(),
        status: :confirmed
      }

      updated_invoices =
        Enum.map(state.invoices, fn inv ->
          if inv.id == invoice_id, do: %{inv | paid: true}, else: inv
        end)

      Logger.info("Recorded charge #{charge.id} for invoice #{invoice_id}: $#{amount}")

      %{state | invoices: updated_invoices, charges: [charge | state.charges]}
    end)

    :ok
  end

  def record_charge(_agent, _invoice_id, amount) do
    {:error, "Invalid amount: #{amount}"}
  end
  # VALIDATION: SMELL END
end

defmodule BillingReporter do
  @moduledoc """
  Generates summary reports from the current billing cycle state.
  """

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because BillingReporter directly calls Agent.get to read
  # the internal structure of the shared Agent, coupling the reporter to the raw state shape.
  def summarize(agent) do
    state = Agent.get(agent, fn s -> s end)

    total_invoiced =
      state.invoices
      |> Enum.map(& &1.total)
      |> Enum.sum()

    total_charged =
      state.charges
      |> Enum.map(& &1.amount)
      |> Enum.sum()

    overdue_count = length(state.flags)

    discount_count = length(state.discounts)

    %{
      total_invoiced: Float.round(total_invoiced, 2),
      total_charged: Float.round(total_charged, 2),
      outstanding: Float.round(total_invoiced - total_charged, 2),
      overdue_invoices: overdue_count,
      discounts_applied: discount_count,
      generated_at: DateTime.utc_now()
    }
  end
  # VALIDATION: SMELL END
end
```
