```elixir
defmodule BillingTracker do
  @moduledoc """
  Tracks active billing sessions and accumulated charges for customers
  during a checkout flow. Stores per-session state shared across the
  request pipeline.
  """

  use Agent

  @type session :: %{
          customer_id: String.t(),
          items: list(map()),
          subtotal: float(),
          discounts: list(map()),
          tax_rate: float(),
          finalized: boolean()
        }

  def start_link(opts \\ []) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @doc "Initializes a new billing session for a customer."
  def open_session(customer_id, tax_rate \\ 0.08) do
    session = %{
      customer_id: customer_id,
      items: [],
      subtotal: 0.0,
      discounts: [],
      tax_rate: tax_rate,
      finalized: false
    }

    Agent.update(__MODULE__, &Map.put(&1, customer_id, session))
    {:ok, customer_id}
  end

  @doc "Adds a line item to the customer's billing session."
  def add_item(customer_id, item) do
    Agent.update(__MODULE__, fn state ->
      session = Map.fetch!(state, customer_id)
      updated_items = [item | session.items]
      new_subtotal = session.subtotal + item.unit_price * item.quantity
      updated_session = %{session | items: updated_items, subtotal: new_subtotal}
      Map.put(state, customer_id, updated_session)
    end)
  end


  @doc "Applies a promotional discount to the session."
  def apply_discount(customer_id, %{code: code, type: type, value: value}) do
    Agent.get_and_update(__MODULE__, fn state ->
      session = Map.fetch!(state, customer_id)

      discount_amount =
        case type do
          :percentage -> Float.round(session.subtotal * (value / 100.0), 2)
          :fixed -> min(value, session.subtotal)
          _ -> 0.0
        end

      updated_discounts = [%{code: code, amount: discount_amount} | session.discounts]
      updated_session = %{session | discounts: updated_discounts}
      new_state = Map.put(state, customer_id, updated_session)
      {{:ok, discount_amount}, new_state}
    end)
  end

  @doc "Generates a formatted invoice map for the current session."
  def generate_invoice(customer_id) do
    Agent.get(__MODULE__, fn state ->
      session = Map.fetch!(state, customer_id)

      total_discounts =
        session.discounts
        |> Enum.map(& &1.amount)
        |> Enum.sum()

      taxable_amount = max(session.subtotal - total_discounts, 0.0)
      tax = Float.round(taxable_amount * session.tax_rate, 2)
      total = Float.round(taxable_amount + tax, 2)

      %{
        invoice_id: "INV-#{:erlang.unique_integer([:positive])}",
        customer_id: customer_id,
        issued_at: DateTime.utc_now(),
        line_items: Enum.reverse(session.items),
        subtotal: session.subtotal,
        discounts: session.discounts,
        total_discounts: total_discounts,
        tax: tax,
        total: total,
        currency: "USD"
      }
    end)
  end

  @doc "Dispatches a receipt notification for a finalized session."
  def send_receipt(customer_id, email) do
    Agent.get(__MODULE__, fn state ->
      invoice = generate_invoice(customer_id)

      receipt_payload = %{
        to: email,
        subject: "Your receipt – Invoice #{invoice.invoice_id}",
        body:
          "Dear customer, your total is $#{invoice.total}. " <>
            "Thank you for your purchase.",
        metadata: %{
          customer_id: customer_id,
          invoice_id: invoice.invoice_id,
          sent_at: DateTime.utc_now()
        }
      }

      {:ok, receipt_payload}
    end)
  end


  @doc "Marks a billing session as finalized."
  def finalize_session(customer_id) do
    Agent.update(__MODULE__, fn state ->
      session = Map.fetch!(state, customer_id)
      Map.put(state, customer_id, %{session | finalized: true})
    end)
  end

  @doc "Removes a completed or abandoned billing session."
  def close_session(customer_id) do
    Agent.update(__MODULE__, &Map.delete(&1, customer_id))
  end

  @doc "Returns the raw session state for a customer."
  def get_session(customer_id) do
    Agent.get(__MODULE__, &Map.get(&1, customer_id))
  end
end
```
