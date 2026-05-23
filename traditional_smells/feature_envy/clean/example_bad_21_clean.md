```elixir
defmodule Reporting.SalesRecord do
  @moduledoc "Represents a closed sales deal for reporting purposes."

  defstruct [
    :id,
    :rep_id,
    :account_id,
    :deal_type,
    :currency,
    :base_amount,
    :discount_pct,
    :region,
    :closed_at,
    :recurring
  ]

  def get!(id) do
    %__MODULE__{
      id: id,
      rep_id: "REP-007",
      account_id: "ACC-512",
      deal_type: :enterprise,
      currency: "USD",
      base_amount: Decimal.new("24000.00"),
      discount_pct: Decimal.new("0.05"),
      region: :north_america,
      closed_at: ~D[2024-03-01],
      recurring: true
    }
  end

  def gross_revenue(%__MODULE__{base_amount: amount, discount_pct: disc}) do
    Decimal.mult(amount, Decimal.sub(Decimal.new("1"), disc))
  end

  def is_recurring?(%__MODULE__{recurring: true}), do: true
  def is_recurring?(_), do: false

  def discount_applied?(%__MODULE__{discount_pct: d}) do
    Decimal.gt?(d, Decimal.new("0"))
  end

  def region_multiplier(%__MODULE__{region: :north_america}), do: Decimal.new("1.10")
  def region_multiplier(%__MODULE__{region: :emea}),          do: Decimal.new("1.05")
  def region_multiplier(%__MODULE__{region: :apac}),          do: Decimal.new("1.08")
  def region_multiplier(_),                                   do: Decimal.new("1.00")

  def deal_label(%__MODULE__{deal_type: :enterprise}),  do: "Enterprise"
  def deal_label(%__MODULE__{deal_type: :mid_market}),  do: "Mid-Market"
  def deal_label(%__MODULE__{deal_type: :smb}),         do: "SMB"
  def deal_label(_),                                    do: "Unknown"
end

defmodule Reporting.SalesReport do
  @moduledoc """
  Generates period-over-period sales reports and computes
  individual representative commissions based on deal attributes.
  """

  alias Reporting.SalesRecord
  require Logger

  @base_commission_rate Decimal.new("0.07")
  @recurring_bonus      Decimal.new("0.02")

  @doc """
  Builds a commission report map for a list of sale IDs in a given period.
  """
  def build_period_report(sale_ids, period_label) do
    rows =
      sale_ids
      |> Enum.map(fn id ->
        record = SalesRecord.get!(id)

        %{
          sale_id:    id,
          rep_id:     record.rep_id,
          deal_label: SalesRecord.deal_label(record),
          commission: compute_rep_commission(id)
        }
      end)

    total = rows |> Enum.map(& &1.commission) |> Enum.reduce(Decimal.new("0"), &Decimal.add/2)

    %{
      period:     period_label,
      rows:       rows,
      total_commissions: Decimal.round(total, 2),
      generated_at: DateTime.utc_now()
    }
  end

  defp compute_rep_commission(sale_id) do
    record   = SalesRecord.get!(sale_id)
    revenue  = SalesRecord.gross_revenue(record)
    rate     = if SalesRecord.is_recurring?(record),
                 do:   Decimal.add(@base_commission_rate, @recurring_bonus),
                 else: @base_commission_rate

    adjusted_rate =
      if SalesRecord.discount_applied?(record) do
        Decimal.sub(rate, Decimal.new("0.01"))
      else
        rate
      end

    multiplier = SalesRecord.region_multiplier(record)
    base_comm  = Decimal.mult(revenue, adjusted_rate)
    Decimal.round(Decimal.mult(base_comm, multiplier), 2)
  end
end
```
