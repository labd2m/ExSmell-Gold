```elixir
defmodule Billing.InvoiceContext do
  @moduledoc """
  The Invoice context manages creation, retrieval, and status transitions
  for customer invoices. Billing policy rules are encapsulated here, keeping
  the web and background layers free of domain logic.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias Billing.{Invoice, LineItem}
  alias Finance.Money

  @type invoice_id :: Ecto.UUID.t()
  @type create_params :: %{
          customer_id: String.t(),
          due_on: Date.t(),
          line_items: [%{description: String.t(), amount_cents: pos_integer()}]
        }

  @doc """
  Creates a new invoice with its associated line items inside a database
  transaction. Returns the persisted invoice with items preloaded.
  """
  @spec create_invoice(create_params()) ::
          {:ok, Invoice.t()} | {:error, Ecto.Changeset.t()}
  def create_invoice(%{customer_id: _, due_on: _, line_items: items} = params)
      when is_list(items) do
    Repo.transaction(fn ->
      with {:ok, invoice} <- insert_invoice(params),
           :ok <- insert_line_items(invoice.id, items) do
        Repo.preload(invoice, :line_items)
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  @doc "Fetches a single invoice by ID, preloading its line items."
  @spec fetch_invoice(invoice_id()) :: {:ok, Invoice.t()} | {:error, :not_found}
  def fetch_invoice(id) when is_binary(id) do
    query = from(i in Invoice, where: i.id == ^id, preload: [:line_items])

    case Repo.one(query) do
      nil -> {:error, :not_found}
      invoice -> {:ok, invoice}
    end
  end

  @doc "Lists all invoices for the given customer ordered by due date descending."
  @spec list_for_customer(String.t()) :: [Invoice.t()]
  def list_for_customer(customer_id) when is_binary(customer_id) do
    Invoice
    |> where([i], i.customer_id == ^customer_id)
    |> order_by([i], desc: i.due_on)
    |> preload(:line_items)
    |> Repo.all()
  end

  @doc """
  Marks an invoice as paid, recording the payment timestamp.
  Returns `{:error, :already_paid}` if the invoice is not in draft status.
  """
  @spec mark_paid(Invoice.t()) :: {:ok, Invoice.t()} | {:error, :already_paid | Ecto.Changeset.t()}
  def mark_paid(%Invoice{status: "paid"}), do: {:error, :already_paid}

  def mark_paid(%Invoice{} = invoice) do
    invoice
    |> Invoice.payment_changeset(%{status: "paid", paid_at: DateTime.utc_now()})
    |> Repo.update()
  end

  @doc "Computes the total amount due from an invoice's line items."
  @spec total(Invoice.t()) :: {:ok, Money.t()} | {:error, :unsupported_currency}
  def total(%Invoice{currency: currency, line_items: items}) when is_list(items) do
    sum = Enum.sum_by(items, & &1.amount_cents)
    Money.new(sum / 100, currency)
  end

  defp insert_invoice(params) do
    %Invoice{}
    |> Invoice.creation_changeset(params)
    |> Repo.insert()
  end

  defp insert_line_items(_invoice_id, []), do: :ok

  defp insert_line_items(invoice_id, items) do
    result =
      Enum.reduce_while(items, :ok, fn item_params, _acc ->
        attrs = Map.put(item_params, :invoice_id, invoice_id)

        case %LineItem{} |> LineItem.changeset(attrs) |> Repo.insert() do
          {:ok, _} -> {:cont, :ok}
          {:error, cs} -> {:halt, {:error, cs}}
        end
      end)

    result
  end
end
```
