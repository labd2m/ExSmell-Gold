```elixir
defmodule MyApp.Finance.AssetDepreciator do
  @moduledoc """
  Computes depreciation schedules for fixed assets.
  Supports straight-line, declining balance, and accelerated depreciation methods.
  Generates depreciation entries for each accounting period.
  """

  alias MyApp.Finance.{Asset, DepreciationPolicy, DepreciationEntry, LedgerPoster}
  alias MyApp.Accounting.Period

  @min_salvage_ratio 0.05

  def compute_depreciation(asset_id, period_id) do
    with {:ok, asset}   <- Asset.fetch(asset_id),
         {:ok, period}  <- Period.fetch(period_id),
         {:ok, policy}  <- DepreciationPolicy.for_asset_class(asset.asset_class) do

      purchase_price   = asset.purchase_price
      salvage_value    = asset.salvage_value
      acquisition_date = asset.acquisition_date
      asset_class      = asset.asset_class

      method           = policy.method
      useful_life      = policy.useful_life_years
      accelerated_rate = policy.accelerated_rate

      depreciable_basis = purchase_price - max(salvage_value, purchase_price * @min_salvage_ratio)
      periods_elapsed   = months_elapsed(acquisition_date, period.start_date)
      total_periods     = useful_life * 12

      if periods_elapsed >= total_periods do
        {:ok, :fully_depreciated}
      else
        charge = case method do
          :straight_line ->
            depreciable_basis / total_periods

          :declining_balance ->
            book_value    = current_book_value(asset_id, purchase_price)
            rate_per_period = (2.0 / useful_life) / 12
            book_value * rate_per_period

          :accelerated ->
            remaining   = total_periods - periods_elapsed
            sum_digits  = total_periods * (total_periods + 1) / 2
            depreciable_basis * (remaining / sum_digits) * accelerated_rate

          _ ->
            depreciable_basis / total_periods
        end

        charge = Float.round(charge, 2)

        entry = %{
          id:          generate_id(),
          asset_id:    asset_id,
          period_id:   period_id,
          asset_class: asset_class,
          method:      method,
          charge:      charge,
          posted_at:   DateTime.utc_now()
        }

        case DepreciationEntry.save(entry) do
          {:ok, saved} ->
            LedgerPoster.post_depreciation(saved)
            {:ok, saved}
          {:error, reason} ->
            {:error, reason}
        end
      end
    end
  end

  def schedule(asset_id) do
    case Asset.fetch(asset_id) do
      {:ok, asset} ->
        entries = DepreciationEntry.list_for_asset(asset_id)
        total_charged = entries |> Enum.map(& &1.charge) |> Enum.sum()
        {:ok, %{
          asset_id:      asset_id,
          purchase_price: asset.purchase_price,
          total_charged:  Float.round(total_charged, 2),
          net_book_value: Float.round(asset.purchase_price - total_charged, 2),
          entry_count:    length(entries)
        }}
      error -> error
    end
  end

  def list_by_class(asset_class, period_id) do
    :ets.tab2list(:depreciation_entries)
    |> Enum.map(fn {_, e} -> e end)
    |> Enum.filter(&(&1.asset_class == asset_class and &1.period_id == period_id))
    |> Enum.sort_by(& &1.posted_at)
  end


  defp months_elapsed(from_date, to_date) do
    years  = to_date.year  - from_date.year
    months = to_date.month - from_date.month
    years * 12 + months
  end

  defp current_book_value(asset_id, purchase_price) do
    charged =
      :ets.tab2list(:depreciation_entries)
      |> Enum.map(fn {_, e} -> e end)
      |> Enum.filter(&(&1.asset_id == asset_id))
      |> Enum.map(& &1.charge)
      |> Enum.sum()
    purchase_price - charged
  end

  defp generate_id do
    "DEP-" <> (:crypto.strong_rand_bytes(6) |> Base.encode16())
  end
end
```
