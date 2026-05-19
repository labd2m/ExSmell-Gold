```elixir
defmodule Billing.InvoiceStore do
  @moduledoc """
  Manages the in-memory lifecycle state for billing invoices.
  This module owns and starts the shared Agent process.
  """

  use Agent

  @initial_state %{
    invoices: %{},
    counter: 10_000,
    total_amount: "0.00",
    currency: "USD"
  }

  def start_link(opts \\ []) do
    Agent.start_link(fn -> @initial_state end, name: Keyword.get(opts, :name, __MODULE__))
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  def all_invoices do
    Agent.get(__MODULE__, & &1.invoices)
  end
end

defmodule Billing.InvoiceCreator do
  @moduledoc """
  Handles creation of new billing invoices for customer orders.
  """

  require Logger
  alias Billing.InvoiceStore

  @tax_rate 0.10

  @doc """
  Creates a new invoice from a list of line items, assigns a unique number,
  and stores it in the shared invoice state.
  """
  def create(order_id, customer_id, line_items) when is_list(line_items) do
    subtotal =
      Enum.reduce(line_items, 0.0, fn item, acc ->
        acc + item.unit_price * item.quantity
      end)

    total = Float.round(subtotal * (1 + @tax_rate), 2)

    {invoice_id, invoice} =
      Agent.get_and_update(InvoiceStore, fn state ->
        seq = state.counter + 1
        invoice_id = "INV-#{seq}"

        invoice = %{
          id: invoice_id,
          order_id: order_id,
          customer_id: customer_id,
          line_items: line_items,
          subtotal: subtotal,
          tax: Float.round(subtotal * @tax_rate, 2),
          total: total,
          currency: state.currency,
          status: :draft,
          due_date: Date.add(Date.utc_today(), 30),
          created_at: DateTime.utc_now(),
          paid_at: nil
        }

        new_state = %{
          state
          | invoices: Map.put(state.invoices, invoice_id, invoice),
            counter: seq
        }

        {{invoice_id, invoice}, new_state}
      end)

    Logger.info("[InvoiceCreator] Created #{invoice_id} for order=#{order_id} total=#{total}")
    {:ok, invoice}
  end
end

defmodule Billing.InvoiceApprover do
  @moduledoc """
  Handles approval and voiding of draft invoices prior to dispatch.
  """

  require Logger
  alias Billing.InvoiceStore

  @doc """
  Transitions a draft invoice to :issued status after approval.
  """
  def approve(invoice_id, approved_by) do
    result =
      Agent.get_and_update(InvoiceStore, fn state ->
        case Map.fetch(state.invoices, invoice_id) do
          {:ok, %{status: :draft} = inv} ->
            updated = %{inv | status: :issued, approved_by: approved_by, issued_at: DateTime.utc_now()}
            new_state = %{state | invoices: Map.put(state.invoices, invoice_id, updated)}
            {{:ok, updated}, new_state}

          {:ok, %{status: current}} ->
            {{:error, {:invalid_transition, current, :issued}}, state}

          :error ->
            {{:error, :not_found}, state}
        end
      end)

    case result do
      {:ok, inv} ->
        Logger.info("[InvoiceApprover] #{invoice_id} approved by #{approved_by}")
        {:ok, inv}

      error ->
        error
    end
  end

  @doc """
  Voids an invoice that has not yet been paid.
  """
  def void(invoice_id, reason) when is_binary(reason) do
    Agent.update(InvoiceStore, fn state ->
      case Map.fetch(state.invoices, invoice_id) do
        {:ok, inv} when inv.status in [:draft, :issued] ->
          updated = %{inv | status: :voided, void_reason: reason, voided_at: DateTime.utc_now()}
          %{state | invoices: Map.put(state.invoices, invoice_id, updated)}

        _ ->
          state
      end
    end)
  end
end

defmodule Billing.PaymentCollector do
  @moduledoc """
  Records incoming payment events and reconciles invoice balances.
  """

  require Logger
  alias Billing.InvoiceStore

  @doc """
  Marks an issued invoice as paid and stores the payment reference.
  """
  def record_payment(invoice_id, payment_ref, paid_amount) when is_float(paid_amount) do
    Agent.get_and_update(InvoiceStore, fn state ->
      case Map.fetch(state.invoices, invoice_id) do
        {:ok, %{status: :issued, total: expected} = inv} ->
          status =
            cond do
              abs(paid_amount - expected) < 0.01 -> :paid
              paid_amount < expected -> :partially_paid
              true -> :overpaid
            end

          updated = %{
            inv
            | status: status,
              payment_ref: payment_ref,
              paid_amount: paid_amount,
              paid_at: DateTime.utc_now()
          }

          new_state = %{state | invoices: Map.put(state.invoices, invoice_id, updated)}
          Logger.info("[PaymentCollector] #{invoice_id} -> #{status} ref=#{payment_ref}")
          {{:ok, updated}, new_state}

        {:ok, %{status: s}} ->
          {{:error, {:wrong_status, s}}, state}

        :error ->
          {{:error, :not_found}, state}
      end
    end)
  end
end

defmodule Billing.InvoiceReporter do
  @moduledoc """
  Generates financial summaries and per-customer reports from invoice state.
  """

  alias Billing.InvoiceStore

  @doc """
  Returns an aggregated financial summary grouped by invoice status.
  """
  def financial_summary do
    Agent.get(InvoiceStore, fn state ->
      invoices = Map.values(state.invoices)
      counts = Enum.frequencies_by(invoices, & &1.status)

      paid_total =
        invoices
        |> Enum.filter(&(&1.status == :paid))
        |> Enum.reduce(0.0, &(&1.paid_amount + &2))

      %{
        currency: state.currency,
        total_count: length(invoices),
        counts: counts,
        paid_total: Float.round(paid_total, 2)
      }
    end)
  end

  @doc """
  Lists invoices for a given customer, sorted newest-first.
  """
  def for_customer(customer_id) do
    Agent.get(InvoiceStore, fn state ->
      state.invoices
      |> Map.values()
      |> Enum.filter(&(&1.customer_id == customer_id))
      |> Enum.sort_by(& &1.created_at, {:desc, DateTime})
    end)
  end
end
```
