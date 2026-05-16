```elixir
defmodule MyApp.Sales.CommissionEngine do
  @moduledoc """
  Calculates sales representative commissions based on closed deals,
  tiered performance thresholds, product category bonuses, and quota attainment.
  """

  require Logger

  alias MyApp.Sales.{SalesRep, DealRecord, CommissionLedger, QuotaTracker}

  @base_commission_rate 0.05
  @tier_thresholds [
    {250_000, 0.02},
    {100_000, 0.01},
    {50_000, 0.005}
  ]
  @category_bonuses %{
    "enterprise" => 0.015,
    "strategic" => 0.01,
    "smb" => 0.0
  }
  @rounding_precision 2

  @type commission_opts :: [
          include_bonuses: boolean(),
          include_breakdown: boolean(),
          period: {Date.t(), Date.t()}
        ]

  @spec calculate(String.t(), String.t(), commission_opts()) ::
          {:ok, map()} | {:error, atom()}
  def calculate(rep_id, deal_id, opts \\ []) do
    include_bonuses = Keyword.get(opts, :include_bonuses, true)
    include_breakdown = Keyword.get(opts, :include_breakdown, false)

    with {:ok, rep} <- SalesRep.fetch(rep_id),
         {:ok, deal} <- DealRecord.fetch(deal_id),
         :ok <- check_deal_closed(deal),
         :ok <- check_not_already_commissioned(deal_id) do

      sale_amount = deal.amount
      commission_rate = rep.commission_rate

      base_commission = Float.round(sale_amount * commission_rate, @rounding_precision)

      tier_bonus =
        if include_bonuses do
          apply_tier_bonus(rep_id, sale_amount, commission_rate)
        else
          0.0
        end

      category_bonus =
        if include_bonuses do
          category_bonus_rate = Map.get(@category_bonuses, deal.category, 0.0)
          Float.round(sale_amount * category_bonus_rate, @rounding_precision)
        else
          0.0
        end

      total_commission = base_commission + tier_bonus + category_bonus

      result = %{
        rep_id: rep_id,
        deal_id: deal_id,
        sale_amount: sale_amount,
        commission_rate: commission_rate,
        base_commission: base_commission,
        tier_bonus: tier_bonus,
        category_bonus: category_bonus,
        total_commission: total_commission
      }

      result =
        if include_breakdown do
          Map.put(result, :breakdown, build_breakdown(sale_amount, commission_rate, deal))
        else
          result
        end

      with :ok <- CommissionLedger.record(rep_id, deal_id, total_commission) do
        Logger.info(
          "Commission calculated: rep=#{rep_id} deal=#{deal_id} " <>
            "amount=#{sale_amount} commission=#{total_commission}"
        )

        {:ok, result}
      end
    end
  end

  @spec period_summary(String.t(), Date.t(), Date.t()) :: {:ok, map()} | {:error, atom()}
  def period_summary(rep_id, date_from, date_to) do
    with {:ok, records} <- CommissionLedger.fetch_range(rep_id, date_from, date_to) do
      total = records |> Enum.map(& &1.amount) |> Enum.sum() |> Float.round(@rounding_precision)

      {:ok,
       %{
         rep_id: rep_id,
         period: %{from: date_from, to: date_to},
         total_commission: total,
         deal_count: length(records),
         records: records
       }}
    end
  end

  @spec quota_attainment(String.t(), integer(), integer()) ::
          {:ok, map()} | {:error, atom()}
  def quota_attainment(rep_id, year, quarter) do
    with {:ok, quota} <- QuotaTracker.fetch(rep_id, year, quarter),
         {:ok, deals} <- DealRecord.closed_in_quarter(rep_id, year, quarter) do
      total_sales = deals |> Enum.map(& &1.amount) |> Enum.sum()
      attainment_pct = Float.round(total_sales / quota.target * 100, 1)

      {:ok,
       %{
         rep_id: rep_id,
         year: year,
         quarter: quarter,
         quota: quota.target,
         achieved: total_sales,
         attainment_percent: attainment_pct
       }}
    end
  end

  # Private helpers

  defp check_deal_closed(%{status: :closed}), do: :ok
  defp check_deal_closed(_), do: {:error, :deal_not_closed}

  defp check_not_already_commissioned(deal_id) do
    case CommissionLedger.exists?(deal_id) do
      false -> :ok
      true -> {:error, :already_commissioned}
    end
  end

  defp apply_tier_bonus(rep_id, sale_amount, base_rate) do
    with {:ok, ytd_sales} <- DealRecord.ytd_total(rep_id) do
      bonus_rate =
        Enum.find_value(@tier_thresholds, 0.0, fn {threshold, bonus} ->
          if ytd_sales >= threshold, do: bonus
        end)

      Float.round(sale_amount * bonus_rate, @rounding_precision)
    else
      _ -> 0.0
    end
  end

  defp build_breakdown(amount, rate, deal) do
    %{
      gross_amount: amount,
      base_rate_applied: rate,
      category: deal.category,
      category_bonus_rate: Map.get(@category_bonuses, deal.category, 0.0)
    }
  end
end
```
