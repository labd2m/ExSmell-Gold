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

defmodule InvoiceAuditor do
  @moduledoc """
  Audits invoices and flags those that are overdue based on due date.
  """

  require Logger

  @grace_period_days 3

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
end

defmodule PaymentGateway do
  @moduledoc """
  Records charges after a payment provider confirms a transaction.
  """

  require Logger

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
end

defmodule BillingReporter do
  @moduledoc """
  Generates summary reports from the current billing cycle state.
  """

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
end
```
