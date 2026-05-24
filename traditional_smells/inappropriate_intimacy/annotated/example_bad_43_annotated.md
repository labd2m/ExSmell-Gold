# Annotated Example — Code Smell

- **Smell name:** Inappropriate Intimacy
- **Expected smell location:** `Reporting.SalesReport.build/2`
- **Affected function(s):** `build/2`, `summarise_rep/2`
- **Short explanation:** `SalesReport` directly accesses internal fields of `Deal` (`deal.stage`, `deal.closed_at`, `deal.amount_cents`, `deal.currency`, `deal.commission_rate`) and `SalesRep` (`rep.quota_cents`, `rep.tier`, `rep.active`) to compute report data. These derivations should be encapsulated within the `Deal` and `SalesRep` modules rather than exposed as raw data to the reporter.

```elixir
defmodule Reporting.SalesReport do
  @moduledoc """
  Generates period sales reports aggregated per sales representative,
  including quota attainment and commission estimates.
  """

  require Logger

  alias CRM.{Deal, SalesRep, Account}
  alias Reporting.ReportSnapshot
  alias Repo

  @closed_stages [:closed_won]
  @base_commission_multipliers %{junior: 1.0, senior: 1.15, principal: 1.30}

  def build(account_id, %Date.Range{} = period) do
    with {:ok, account} <- Account.fetch(account_id),
         {:ok, reps} <- SalesRep.list_for_account(account_id),
         {:ok, deals} <- Deal.list_for_period(account_id, period) do
      rep_summaries =
        reps
        |> Enum.map(fn rep -> summarise_rep(rep, deals) end)
        |> Enum.sort_by(& &1.total_revenue_cents, :desc)

      snapshot = %ReportSnapshot{
        account_id: account_id,
        account_name: account.name,
        period_start: period.first,
        period_end: period.last,
        generated_at: DateTime.utc_now(),
        rep_summaries: rep_summaries,
        grand_total_cents: Enum.sum_by(rep_summaries, & &1.total_revenue_cents)
      }

      case Repo.insert(snapshot) do
        {:ok, saved} ->
          Logger.info("Sales report #{saved.id} generated for account #{account_id}")
          {:ok, saved}

        {:error, changeset} ->
          Logger.error("Failed to persist sales report: #{inspect(changeset.errors)}")
          {:error, :persistence_failed}
      end
    end
  end

  # VALIDATION: SMELL START - Inappropriate Intimacy
  # VALIDATION: This is a smell because summarise_rep/2 directly reads internal fields
  # VALIDATION: of Deal (stage, closed_at, amount_cents, currency, commission_rate) and
  # VALIDATION: SalesRep (quota_cents, tier, active) to derive business metrics like
  # VALIDATION: quota attainment and commissions. These computations should live inside
  # VALIDATION: the Deal and SalesRep modules, not be reconstructed here.
  defp summarise_rep(rep, all_deals) do
    unless rep.active do
      nil
    else
      rep_deals =
        Enum.filter(all_deals, fn deal ->
          deal.owner_id == rep.id and deal.stage in @closed_stages
        end)

      total_revenue_cents =
        Enum.reduce(rep_deals, 0, fn deal, acc ->
          normalised = normalise_to_usd(deal.amount_cents, deal.currency)
          acc + normalised
        end)

      commission_multiplier = Map.get(@base_commission_multipliers, rep.tier, 1.0)

      total_commission_cents =
        Enum.reduce(rep_deals, 0, fn deal, acc ->
          base = deal.amount_cents * deal.commission_rate
          acc + round(base * commission_multiplier)
        end)

      quota_attainment =
        if rep.quota_cents > 0 do
          Float.round(total_revenue_cents / rep.quota_cents * 100, 2)
        else
          0.0
        end

      deal_count = length(rep_deals)
      avg_deal_size = if deal_count > 0, do: div(total_revenue_cents, deal_count), else: 0

      %{
        rep_id: rep.id,
        rep_name: rep.full_name,
        tier: rep.tier,
        deal_count: deal_count,
        total_revenue_cents: total_revenue_cents,
        total_commission_cents: total_commission_cents,
        quota_cents: rep.quota_cents,
        quota_attainment_pct: quota_attainment,
        avg_deal_size_cents: avg_deal_size
      }
    end
  end
  # VALIDATION: SMELL END

  defp normalise_to_usd(amount_cents, "USD"), do: amount_cents

  defp normalise_to_usd(amount_cents, currency) do
    rate = ExchangeRates.get_rate(currency, "USD")
    round(amount_cents * rate)
  end

  def export_csv(%ReportSnapshot{} = snapshot) do
    rows =
      snapshot.rep_summaries
      |> Enum.filter(& &1)
      |> Enum.map(fn s ->
        [
          s.rep_name,
          s.tier,
          s.deal_count,
          format_currency(s.total_revenue_cents),
          format_currency(s.quota_cents),
          "#{s.quota_attainment_pct}%"
        ]
      end)

    header = ["Rep Name", "Tier", "Deals", "Revenue", "Quota", "Attainment"]
    [header | rows]
    |> CSV.encode()
    |> Enum.to_list()
    |> IO.iodata_to_binary()
  end

  defp format_currency(cents) do
    "$#{:erlang.float_to_binary(cents / 100, decimals: 2)}"
  end
end
```
