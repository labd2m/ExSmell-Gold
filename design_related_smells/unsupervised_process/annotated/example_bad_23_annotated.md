# Code Smell: Unsupervised Process

- **Smell name:** Unsupervised Process
- **Expected smell location:** `BillingWorker.start/1`
- **Affected function(s):** `BillingWorker.start/1`, `InvoiceProcessor.process_batch/1`
- **Short explanation:** `BillingWorker` is started with `GenServer.start/3` (not `start_link`) and is never added to a supervision tree. When `InvoiceProcessor.process_batch/1` spawns one worker per invoice batch, those long-running processes are invisible to any supervisor, making restart, shutdown, and observability impossible.

```elixir
defmodule BillingWorker do
  use GenServer

  @moduledoc """
  GenServer responsible for processing a single billing batch.
  Accumulates line items, applies tax rules, and emits the final invoice total.
  """

  defstruct [:batch_id, :customer_id, :line_items, :tax_rate, :status]

  # VALIDATION: SMELL START - Unsupervised Process
  # VALIDATION: This is a smell because `GenServer.start/3` is used instead of
  # `GenServer.start_link/3`, and no supervision tree is informed of this process.
  # Long-running workers created here are untracked and cannot be restarted or
  # shut down in a controlled manner.
  def start(batch_id) do
    GenServer.start(__MODULE__, batch_id, name: via(batch_id))
  end
  # VALIDATION: SMELL END

  defp via(batch_id) do
    {:via, Registry, {BillingRegistry, batch_id}}
  end

  def add_line_item(batch_id, item) do
    GenServer.call(via(batch_id), {:add_item, item})
  end

  def finalize(batch_id) do
    GenServer.call(via(batch_id), :finalize)
  end

  def status(batch_id) do
    GenServer.call(via(batch_id), :status)
  end

  ## Callbacks

  @impl true
  def init(batch_id) do
    state = %__MODULE__{
      batch_id: batch_id,
      customer_id: nil,
      line_items: [],
      tax_rate: 0.10,
      status: :open
    }
    {:ok, state}
  end

  @impl true
  def handle_call({:add_item, %{customer_id: cid} = item}, _from, %{status: :open} = state) do
    updated = %{state | line_items: [item | state.line_items], customer_id: cid}
    {:reply, :ok, updated}
  end

  def handle_call({:add_item, _item}, _from, state) do
    {:reply, {:error, :batch_closed}, state}
  end

  def handle_call(:finalize, _from, %{status: :open} = state) do
    subtotal =
      Enum.reduce(state.line_items, Decimal.new("0"), fn item, acc ->
        Decimal.add(acc, item.amount)
      end)

    tax = Decimal.mult(subtotal, Decimal.from_float(state.tax_rate))
    total = Decimal.add(subtotal, tax)

    result = %{
      batch_id: state.batch_id,
      customer_id: state.customer_id,
      subtotal: subtotal,
      tax: tax,
      total: total
    }

    {:reply, {:ok, result}, %{state | status: :closed}}
  end

  def handle_call(:finalize, _from, state) do
    {:reply, {:error, :already_finalized}, state}
  end

  def handle_call(:status, _from, state) do
    {:reply, state.status, state}
  end
end

defmodule InvoiceProcessor do
  @moduledoc """
  Orchestrates batch invoice processing by spinning up one BillingWorker per batch.
  """

  def process_batch(batch_id, line_items) do
    {:ok, _pid} = BillingWorker.start(batch_id)

    Enum.each(line_items, fn item ->
      :ok = BillingWorker.add_line_item(batch_id, item)
    end)

    case BillingWorker.finalize(batch_id) do
      {:ok, invoice} ->
        emit_invoice(invoice)
        {:ok, invoice}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp emit_invoice(invoice) do
    IO.inspect(invoice, label: "[InvoiceProcessor] Emitted invoice")
  end
end
```
