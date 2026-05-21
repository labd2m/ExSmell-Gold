# Code Smell Annotation

- **Smell name:** Data manipulation by migration
- **Expected smell location:** `change/0` function
- **Affected function(s):** `change/0`, `compute_invoice_totals/0`
- **Short explanation:** The migration adds `subtotal_cents`, `tax_cents`, and `total_cents` columns to `invoices` and then performs aggregate queries across the `invoice_line_items` table to compute and write these totals for every existing invoice. Aggregating related records and writing summary values back is data manipulation that should not be part of an `Ecto.Migration`.

---

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

    # VALIDATION: SMELL START - Data manipulation by migration
    # VALIDATION: This is a smell because the migration queries the
    # invoice_line_items table to compute aggregate totals (subtotal, tax,
    # total) for each existing invoice and then writes those computed values
    # back to the invoices table. This cross-table aggregation and data
    # backfill is a data manipulation concern that should be isolated in a
    # separate Mix task rather than embedded in Ecto.Migration.change/0.
    compute_invoice_totals()
    # VALIDATION: SMELL END
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
