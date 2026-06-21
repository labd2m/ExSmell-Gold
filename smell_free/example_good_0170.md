```elixir
defmodule Billing.LineItem do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          invoice_id: Ecto.UUID.t(),
          description: String.t(),
          quantity: pos_integer(),
          unit_amount_cents: non_neg_integer(),
          currency: String.t()
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "billing_line_items" do
    field :invoice_id, :binary_id
    field :description, :string
    field :quantity, :integer
    field :unit_amount_cents, :integer
    field :currency, :string
    timestamps(type: :utc_datetime)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(item, params) do
    item
    |> cast(params, [:invoice_id, :description, :quantity, :unit_amount_cents, :currency])
    |> validate_required([:invoice_id, :description, :quantity, :unit_amount_cents, :currency])
    |> validate_number(:quantity, greater_than: 0)
    |> validate_number(:unit_amount_cents, greater_than_or_equal_to: 0)
    |> validate_length(:currency, is: 3)
  end

  @spec subtotal_cents(t()) :: non_neg_integer()
  def subtotal_cents(%__MODULE__{quantity: qty, unit_amount_cents: unit}), do: qty * unit
end

defmodule Billing.Invoice do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @type status :: :draft | :issued | :paid | :void

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          customer_id: Ecto.UUID.t(),
          status: status(),
          currency: String.t(),
          issued_at: DateTime.t() | nil,
          due_date: Date.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "billing_invoices" do
    field :customer_id, :binary_id
    field :status, Ecto.Enum, values: [:draft, :issued, :paid, :void], default: :draft
    field :currency, :string
    field :issued_at, :utc_datetime
    field :due_date, :date
    has_many :line_items, Billing.LineItem, foreign_key: :invoice_id
    timestamps(type: :utc_datetime)
  end

  @spec creation_changeset(t(), map()) :: Ecto.Changeset.t()
  def creation_changeset(invoice, params) do
    invoice
    |> cast(params, [:customer_id, :currency, :due_date])
    |> validate_required([:customer_id, :currency])
    |> validate_length(:currency, is: 3)
  end

  @spec issue_changeset(t()) :: Ecto.Changeset.t()
  def issue_changeset(%__MODULE__{status: :draft} = invoice) do
    change(invoice, status: :issued, issued_at: DateTime.utc_now())
  end

  def issue_changeset(invoice), do: add_error(change(invoice), :status, "must be draft to issue")
end

defmodule Billing do
  @moduledoc """
  Public context for invoice and line-item lifecycle management.

  Invoices begin in the `:draft` state and transition to `:issued` once
  all line items are confirmed. Total calculations are derived from the
  persisted line items; no denormalised total column is maintained,
  preventing drift between stored and calculated values.
  """

  import Ecto.Query, warn: false

  alias Billing.{Invoice, LineItem, Repo}

  @spec create_invoice(map()) :: {:ok, Invoice.t()} | {:error, Ecto.Changeset.t()}
  def create_invoice(params) do
    %Invoice{} |> Invoice.creation_changeset(params) |> Repo.insert()
  end

  @spec add_line_item(Invoice.t(), map()) ::
          {:ok, LineItem.t()} | {:error, Ecto.Changeset.t() | :invoice_not_draft}
  def add_line_item(%Invoice{status: :draft, id: invoice_id}, params) do
    %LineItem{}
    |> LineItem.changeset(Map.put(params, :invoice_id, invoice_id))
    |> Repo.insert()
  end

  def add_line_item(%Invoice{}, _params), do: {:error, :invoice_not_draft}

  @spec issue_invoice(Invoice.t()) :: {:ok, Invoice.t()} | {:error, Ecto.Changeset.t()}
  def issue_invoice(%Invoice{} = invoice) do
    invoice |> Invoice.issue_changeset() |> Repo.update()
  end

  @spec total_cents(Invoice.t()) :: non_neg_integer()
  def total_cents(%Invoice{id: id}) do
    LineItem
    |> where([li], li.invoice_id == ^id)
    |> select([li], coalesce(sum(li.quantity * li.unit_amount_cents), 0))
    |> Repo.one()
  end

  @spec get_invoice_with_items(Ecto.UUID.t()) :: {:ok, Invoice.t()} | {:error, :not_found}
  def get_invoice_with_items(id) when is_binary(id) do
    case Invoice |> Repo.get(id) |> Repo.preload(:line_items) do
      nil -> {:error, :not_found}
      invoice -> {:ok, invoice}
    end
  end
end
```
