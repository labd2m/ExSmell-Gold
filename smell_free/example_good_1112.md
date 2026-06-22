```elixir
defmodule Billing.Invoices do
  @moduledoc """
  Context for building, persisting, and finalizing customer invoices.
  An invoice moves through states: `:draft` → `:issued` → `:paid` | `:void`.
  State transitions are guarded to prevent invalid progressions.
  """

  alias Billing.{Invoice, LineItem, Repo}
  import Ecto.Query

  @type transition_error :: {:error, :invalid_transition | :already_finalized | Ecto.Changeset.t()}

  @doc "Creates a draft invoice with no line items."
  @spec create_draft(map()) :: {:ok, Invoice.t()} | {:error, Ecto.Changeset.t()}
  def create_draft(attrs) when is_map(attrs) do
    attrs
    |> Map.put("status", "draft")
    |> Invoice.changeset()
    |> Repo.insert()
  end

  @doc "Appends a line item to a draft invoice."
  @spec add_line_item(Invoice.t(), map()) ::
          {:ok, LineItem.t()} | {:error, :not_draft | Ecto.Changeset.t()}
  def add_line_item(%Invoice{status: :draft} = invoice, attrs) when is_map(attrs) do
    attrs
    |> Map.put("invoice_id", invoice.id)
    |> LineItem.changeset()
    |> Repo.insert()
  end

  def add_line_item(%Invoice{}, _attrs), do: {:error, :not_draft}

  @doc "Issues a draft invoice, computing the total from its line items."
  @spec issue(Invoice.t()) :: {:ok, Invoice.t()} | transition_error()
  def issue(%Invoice{status: :draft} = invoice) do
    total = compute_total(invoice.id)
    invoice
    |> Invoice.changeset(%{status: "issued", total_cents: total})
    |> Repo.update()
  end

  def issue(%Invoice{}), do: {:error, :invalid_transition}

  @doc "Records payment against an issued invoice."
  @spec pay(Invoice.t()) :: {:ok, Invoice.t()} | transition_error()
  def pay(%Invoice{status: :issued} = invoice) do
    invoice
    |> Invoice.changeset(%{status: "paid"})
    |> Repo.update()
  end

  def pay(%Invoice{}), do: {:error, :invalid_transition}

  @doc "Voids an invoice that has not yet been paid."
  @spec void(Invoice.t()) :: {:ok, Invoice.t()} | transition_error()
  def void(%Invoice{status: s} = invoice) when s in [:draft, :issued] do
    invoice
    |> Invoice.changeset(%{status: "void"})
    |> Repo.update()
  end

  def void(%Invoice{status: :paid}), do: {:error, :already_finalized}
  def void(%Invoice{}), do: {:error, :invalid_transition}

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp compute_total(invoice_id) do
    from(li in LineItem,
      where: li.invoice_id == ^invoice_id,
      select: coalesce(sum(li.amount_cents), 0)
    )
    |> Repo.one()
  end
end

defmodule Billing.InvoiceSummary do
  @moduledoc "Read-only queries for invoice reporting across a customer's account."

  alias Billing.{Invoice, Repo}
  import Ecto.Query

  @type summary :: %{total_cents: integer(), count: non_neg_integer(), status: String.t()}

  @doc "Returns per-status aggregate totals for a customer."
  @spec by_status(String.t()) :: [summary()]
  def by_status(customer_id) when is_binary(customer_id) do
    from(inv in Invoice,
      where: inv.customer_id == ^customer_id,
      group_by: inv.status,
      select: %{
        status: inv.status,
        count: count(inv.id),
        total_cents: coalesce(sum(inv.total_cents), 0)
      }
    )
    |> Repo.all()
  end

  @doc "Returns all unpaid issued invoices older than the given number of days."
  @spec overdue(pos_integer()) :: [Invoice.t()]
  def overdue(days) when is_integer(days) and days > 0 do
    cutoff = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)
    from(inv in Invoice,
      where: inv.status == :issued and inv.inserted_at < ^cutoff,
      order_by: [asc: inv.inserted_at]
    )
    |> Repo.all()
  end
end
```
