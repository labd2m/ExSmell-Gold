```elixir
defmodule Billing.InvoiceService do
  @moduledoc """
  Service layer for managing customer invoices.
  Provides retrieval, formatting, and enrichment of invoice records.
  """

  alias Billing.Repo
  alias Billing.Schema.{Invoice, LineItem}

  @type invoice_id :: pos_integer()

  @doc """
  Fetches an invoice by ID.

  ## Options

    * `:format` - When set to `:json`, returns the invoice serialized as a
      JSON binary string. When set to `:map`, returns a plain map with
      string keys. Defaults to returning the `%Invoice{}` struct.
    * `:include_items` - When `true`, returns a `{invoice, line_items}`
      tuple instead of just the invoice. Cannot be combined with
      `:format` option.

  ## Examples

      iex> InvoiceService.fetch_invoice(42)
      %Invoice{id: 42, ...}

      iex> InvoiceService.fetch_invoice(42, format: :json)
      "{\"id\":42,\"amount\":\"199.00\",...}"

      iex> InvoiceService.fetch_invoice(42, format: :map)
      %{"id" => 42, "amount" => "199.00", ...}

      iex> InvoiceService.fetch_invoice(42, include_items: true)
      {%Invoice{id: 42, ...}, [%LineItem{...}, ...]}

  """

  def fetch_invoice(invoice_id, opts \\ []) when is_list(opts) do
    invoice = Repo.get!(Invoice, invoice_id)

    cond do
      opts[:format] == :json ->
        Jason.encode!(%{
          id: invoice.id,
          number: invoice.number,
          customer_id: invoice.customer_id,
          amount: Decimal.to_string(invoice.amount),
          status: invoice.status,
          issued_at: Date.to_iso8601(invoice.issued_at),
          due_at: Date.to_iso8601(invoice.due_at)
        })

      opts[:format] == :map ->
        %{
          "id" => invoice.id,
          "number" => invoice.number,
          "customer_id" => invoice.customer_id,
          "amount" => Decimal.to_string(invoice.amount),
          "status" => invoice.status,
          "issued_at" => Date.to_iso8601(invoice.issued_at),
          "due_at" => Date.to_iso8601(invoice.due_at)
        }

      opts[:include_items] == true ->
        line_items =
          LineItem
          |> Repo.all_by(invoice_id: invoice.id)
          |> Enum.sort_by(& &1.position)

        {invoice, line_items}

      true ->
        invoice
    end
  end

  @doc """
  Creates a new invoice for a customer.
  """
  def create_invoice(customer_id, attrs) do
    %Invoice{}
    |> Invoice.changeset(Map.merge(attrs, %{customer_id: customer_id}))
    |> Repo.insert()
  end

  @doc """
  Marks an invoice as paid, recording the payment timestamp.
  """
  def mark_paid(%Invoice{} = invoice) do
    invoice
    |> Invoice.payment_changeset(%{status: :paid, paid_at: DateTime.utc_now()})
    |> Repo.update()
  end

  @doc """
  Voids an invoice that has not yet been paid.
  """
  def void_invoice(%Invoice{status: :paid}),
    do: {:error, :already_paid}

  def void_invoice(%Invoice{} = invoice) do
    invoice
    |> Invoice.status_changeset(%{status: :void})
    |> Repo.update()
  end

  @doc """
  Returns total outstanding balance for a customer across all open invoices.
  """
  def outstanding_balance(customer_id) do
    Invoice
    |> Repo.all_by(customer_id: customer_id, status: :open)
    |> Enum.reduce(Decimal.new(0), fn inv, acc ->
      Decimal.add(acc, inv.amount)
    end)
  end
end
```
