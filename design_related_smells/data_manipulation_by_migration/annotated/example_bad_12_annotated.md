# Code Smell: Data Manipulation by Migration

## Metadata

- **Smell name:** Data Manipulation by Migration
- **Expected smell location:** `change/0` and `backfill_totals/0`
- **Affected functions:** `change/0`, `backfill_totals/0`
- **Short explanation:** This migration adds `subtotal_cents`, `tax_cents`, and `total_cents` columns to the `invoices` table (structural change) and then aggregates data from the `invoice_line_items` table to populate those columns (data manipulation). Cross-table data aggregation during a migration increases the risk of data inconsistencies and should be handled in a separate Mix task.

---

```elixir
defmodule Finance.Repo.Migrations.AddDenormalizedTotalsToInvoices do
  use Ecto.Migration

  import Ecto.Query
  alias Finance.Repo

  @tax_rate Decimal.new("0.08")

  def change do
    alter table("invoices") do
      add :subtotal_cents, :integer, null: true
      add :tax_cents,      :integer, null: true
      add :total_cents,    :integer, null: true
    end

    create index("invoices", [:total_cents])

    flush()

    # VALIDATION: SMELL START - Data Manipulation by Migration
    # VALIDATION: This is a smell because the migration joins invoice_line_items to
    # compute aggregate totals and writes those values back to invoices — a classic
    # data manipulation operation that has no place in an Ecto.Migration module.
    # It makes the migration slow on large datasets and hard to test in isolation.
    backfill_totals()
    # VALIDATION: SMELL END
  end

  defp backfill_totals do
    invoice_ids =
      from(i in "invoices",
        where: is_nil(i.total_cents),
        select: i.id
      )
      |> Repo.all()

    Enum.each(invoice_ids, fn invoice_id ->
      subtotal =
        from(li in "invoice_line_items",
          where: li.invoice_id == ^invoice_id,
          select: sum(li.amount_cents)
        )
        |> Repo.one()
        |> Kernel.||(0)

      tax   = round(subtotal * Decimal.to_float(@tax_rate))
      total = subtotal + tax

      from(i in "invoices", where: i.id == ^invoice_id)
      |> Repo.update_all(
        set: [
          subtotal_cents: subtotal,
          tax_cents:      tax,
          total_cents:    total
        ]
      )
    end)
  end
end
```
