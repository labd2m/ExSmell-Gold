```elixir
defmodule Commerce.Billing do
  @moduledoc """
  Context for invoice creation, payment recording, and balance queries.

  All mutations are performed inside Ecto transactions. Queries are
  paginated and scoped strictly to the requesting account.
  """

  import Ecto.Query, only: [from: 2]
  alias Ecto.Multi
  alias Commerce.Repo
  alias Commerce.Billing.{Invoice, LineItem, Payment}

  @type invoice_attrs :: %{
          required(:account_id) => pos_integer(),
          required(:due_date) => Date.t(),
          optional(:currency) => String.t(),
          optional(:line_items) => [map()]
        }

  @type payment_attrs :: %{
          required(:amount_cents) => non_neg_integer(),
          required(:method) => :card | :bank_transfer | :credit,
          required(:reference) => String.t()
        }

  @doc """
  Creates a new invoice with associated line items in a single transaction.
  """
  @spec create_invoice(invoice_attrs()) :: {:ok, Invoice.t()} | {:error, Ecto.Changeset.t()}
  def create_invoice(attrs) do
    line_items = Map.get(attrs, :line_items, [])
    invoice_attrs = Map.drop(attrs, [:line_items])

    Multi.new()
    |> Multi.insert(:invoice, Invoice.changeset(%Invoice{}, invoice_attrs))
    |> Multi.merge(&build_line_item_multi(&1.invoice.id, line_items))
    |> Repo.transaction()
    |> extract_result(:invoice)
  end

  @doc """
  Records a payment against an invoice and marks it as paid, atomically.
  """
  @spec record_payment(Invoice.t(), payment_attrs()) ::
          {:ok, %{invoice: Invoice.t(), payment: Payment.t()}} | {:error, Ecto.Changeset.t()}
  def record_payment(%Invoice{} = invoice, attrs) do
    Multi.new()
    |> Multi.update(:invoice, Invoice.mark_paid_changeset(invoice))
    |> Multi.insert(:payment, Payment.changeset(%Payment{}, Map.put(attrs, :invoice_id, invoice.id)))
    |> Repo.transaction()
    |> extract_keys([:invoice, :payment])
  end

  @doc """
  Returns a paginated list of invoices for an account, newest first.
  """
  @spec list_invoices(pos_integer(), keyword()) :: [Invoice.t()]
  def list_invoices(account_id, opts \\ []) when is_integer(account_id) and account_id > 0 do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 20)

    from(i in Invoice,
      where: i.account_id == ^account_id,
      order_by: [desc: i.inserted_at],
      limit: ^per_page,
      offset: ^((page - 1) * per_page)
    )
    |> Repo.all()
  end

  @doc """
  Fetches a single invoice by id and account, returning an error if not found.
  """
  @spec fetch_invoice(pos_integer(), pos_integer()) :: {:ok, Invoice.t()} | {:error, :not_found}
  def fetch_invoice(invoice_id, account_id)
      when is_integer(invoice_id) and is_integer(account_id) do
    from(i in Invoice, where: i.id == ^invoice_id and i.account_id == ^account_id)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      invoice -> {:ok, invoice}
    end
  end

  @doc """
  Computes the total unpaid balance (in cents) for a given account.
  """
  @spec outstanding_balance(pos_integer()) :: non_neg_integer()
  def outstanding_balance(account_id) when is_integer(account_id) and account_id > 0 do
    from(i in Invoice,
      where: i.account_id == ^account_id and i.status == :unpaid,
      select: sum(i.total_cents)
    )
    |> Repo.one()
    |> normalize_sum()
  end

  defp build_line_item_multi(invoice_id, items) do
    items
    |> Enum.with_index()
    |> Enum.reduce(Multi.new(), fn {item, idx}, multi ->
      changeset = LineItem.changeset(%LineItem{}, Map.put(item, :invoice_id, invoice_id))
      Multi.insert(multi, {:line_item, idx}, changeset)
    end)
  end

  defp extract_result({:ok, result}, key), do: {:ok, result[key]}
  defp extract_result({:error, _step, changeset, _}, _key), do: {:error, changeset}

  defp extract_keys({:ok, result}, keys), do: {:ok, Map.take(result, keys)}
  defp extract_keys({:error, _step, changeset, _}, _keys), do: {:error, changeset}

  defp normalize_sum(nil), do: 0
  defp normalize_sum(value) when is_integer(value), do: value
end
```
