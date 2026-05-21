# Code Smell Example 46

- **Smell name:** Data manipulation by migration
- **Expected smell location:** `change/0` function
- **Affected function(s):** `change/0`, `recalculate_order_totals/0`
- **Short explanation:** The migration adds a `tax_amount` column to `orders` (structural change) and then iterates over all existing orders to compute and persist a tax amount based on their subtotal (data manipulation), embedding business calculation logic inside a schema migration module.

```elixir
defmodule PaymentsApp.Repo.Migrations.AddTaxAmountToOrders do
  use Ecto.Migration

  import Ecto.Query
  alias PaymentsApp.Repo

  @default_tax_rate Decimal.new("0.0875")

  def change do
    alter table("orders") do
      add :tax_amount,      :decimal, precision: 10, scale: 2, null: true
      add :tax_rate,        :decimal, precision: 5,  scale: 4, null: true
      add :tax_calculated_at, :utc_datetime, null: true
    end

    create index("orders", [:tax_calculated_at])

    flush()

    # VALIDATION: SMELL START - Data manipulation by migration
    # VALIDATION: This is a smell because after adding tax-related columns the
    # migration reads every existing order's subtotal, applies a tax rate formula,
    # and writes back computed values. Embedding this financial calculation logic
    # inside a migration mixes structural schema changes with data transformation.
    recalculate_order_totals()
    # VALIDATION: SMELL END
  end

  defp recalculate_order_totals do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(o in "orders",
      where: not is_nil(o.subtotal) and is_nil(o.tax_amount),
      select: {o.id, o.subtotal}
    )
    |> Repo.all()
    |> Enum.each(fn {id, subtotal} ->
      tax =
        subtotal
        |> Decimal.mult(@default_tax_rate)
        |> Decimal.round(2)

      from(o in "orders",
        where: o.id == ^id,
        update: [
          set: [
            tax_amount: ^tax,
            tax_rate: ^@default_tax_rate,
            tax_calculated_at: ^now
          ]
        ]
      )
      |> Repo.update_all([])
    end)
  end
end
```
