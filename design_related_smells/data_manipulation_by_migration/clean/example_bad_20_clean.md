```elixir
defmodule Marketplace.Repo.Migrations.AddTaxFieldsToVendors do
  use Ecto.Migration

  import Ecto.Query
  alias Marketplace.Repo

  @state_tax_rates %{
    "CA" => {Decimal.new("0.0725"), "state_sales_tax"},
    "TX" => {Decimal.new("0.0625"), "state_sales_tax"},
    "NY" => {Decimal.new("0.04"),   "state_sales_tax"},
    "FL" => {Decimal.new("0.06"),   "state_sales_tax"},
    "WA" => {Decimal.new("0.065"),  "state_sales_tax"},
    "OR" => {Decimal.new("0.0"),    "no_sales_tax"},
    "MT" => {Decimal.new("0.0"),    "no_sales_tax"},
    "NH" => {Decimal.new("0.0"),    "no_sales_tax"}
  }

  @default_rate     Decimal.new("0.05")
  @default_category "standard"

  def change do
    alter table("vendors") do
      add :tax_rate,     :decimal, precision: 6, scale: 4, null: true
      add :tax_category, :string,  null: true, size: 50
    end

    create index("vendors", [:tax_category])

    flush()

    assign_default_tax_rates()
  end

  defp assign_default_tax_rates do
    from(v in "vendors",
      where: is_nil(v.tax_rate),
      select: %{id: v.id, state: v.state_code, vendor_type: v.vendor_type}
    )
    |> Repo.all()
    |> Enum.each(fn %{id: id, state: state, vendor_type: vendor_type} ->
      {rate, category} = tax_rate_for(state, vendor_type)

      from(v in "vendors", where: v.id == ^id)
      |> Repo.update_all(set: [tax_rate: rate, tax_category: category])
    end)
  end

  defp tax_rate_for(state, _vendor_type) when is_binary(state) do
    Map.get(@state_tax_rates, String.upcase(state), {@default_rate, @default_category})
  end

  defp tax_rate_for(_, _), do: {@default_rate, @default_category}
end
```
