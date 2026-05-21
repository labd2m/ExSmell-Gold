```elixir
defmodule Billing.Repo.Migrations.AddTotalsToInvoices do
  use Ecto.Migration

  import Ecto.Query
  alias Billing.Repo

  @default_tax_rate Decimal.new("0.08")

  def change do
    alter table("invoices") do
      add :subtotal_cents, :integer, null: true
      add :tax_cents,      :integer, null: true
      add :total_cents,    :integer, null: true
      add :totals_version, :integer, default: 1, null: false
    end

    create index("invoices", [:total_cents])

    flush()

    compute_invoice_totals()
  end

  defp compute_invoice_totals do
    invoice_ids =
      from(i in "invoices", select: i.id)
      |> Repo.all()

    Enum.each(invoice_ids, fn invoice_id ->
      subtotal =
        from(li in "invoice_line_items",
          where: li.invoice_id == ^invoice_id,
          select: sum(li.amount_cents)
        )
        |> Repo.one() || 0

      tax = round(subtotal * Decimal.to_float(@default_tax_rate))
      total = subtotal + tax

      from(i in "invoices", where: i.id == ^invoice_id)
      |> Repo.update_all(
        set: [subtotal_cents: subtotal, tax_cents: tax, total_cents: total]
      )
    end)
  end
end
```
