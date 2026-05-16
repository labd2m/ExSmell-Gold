# Example 48: Ad Campaign Budget Pacing Service

```elixir
defmodule Advertising.BudgetPacer do
  @moduledoc """
  Controls ad campaign spend pacing, daily cap enforcement, budget
  reallocation across line items, and overspend alerting.
  """

  alias Advertising.{Campaign, LineItem, SpendRecord, PacingAlert, BudgetLog, AuditLog}

  @overspend_threshold_pct 1.05
  @underpace_threshold_pct 0.80
  @pacing_check_interval_hours 4

  def get_pacing_status(campaign_id) do
    with {:ok, campaign} <- Campaign.get(campaign_id),
         {:ok, spend} <- SpendRecord.total_for_campaign(campaign_id) do

      days_elapsed = Date.diff(Date.utc_today(), campaign.flight_start_date) + 1
      days_total = Date.diff(campaign.flight_end_date, campaign.flight_start_date) + 1
      days_remaining = max(0, days_total - days_elapsed)

      expected_spend = campaign.total_budget * (days_elapsed / days_total)
      pacing_ratio = if expected_spend > 0, do: spend.total / expected_spend, else: 1.0

      status =
        cond do
          pacing_ratio > @overspend_threshold_pct -> :overpacing
          pacing_ratio < @underpace_threshold_pct -> :underpacing
          true -> :on_pace
        end

      {:ok, %{
        campaign_id: campaign_id,
        status: status,
        total_budget: campaign.total_budget,
        total_spend: spend.total,
        expected_spend: Float.round(expected_spend, 2),
        pacing_ratio: Float.round(pacing_ratio, 4),
        days_elapsed: days_elapsed,
        days_remaining: days_remaining
      }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def update_daily_cap(campaign_id, total_budget, flight_days) do
    with {:ok, campaign} <- Campaign.get(campaign_id),
         {:ok, spend_to_date} <- SpendRecord.total_for_campaign(campaign_id),
         :ok <- validate_campaign_active(campaign) do

      days_remaining = flight_days - Date.diff(Date.utc_today(), campaign.flight_start_date)
      remaining_budget = total_budget - spend_to_date.total

      daily_cap =
        if days_remaining > 0 do
          remaining_budget / days_remaining
        else
          0.0
        end

      adjusted_cap = daily_cap * pacing_multiplier(campaign)

      {:ok, _} = Campaign.update(campaign_id, %{
        daily_cap: Float.round(adjusted_cap, 2),
        total_budget: total_budget,
        cap_updated_at: DateTime.utc_now()
      })

      {:ok, _} = BudgetLog.record(%{
        campaign_id: campaign_id,
        previous_cap: campaign.daily_cap,
        new_cap: Float.round(adjusted_cap, 2),
        total_budget: total_budget,
        days_remaining: days_remaining,
        remaining_budget: Float.round(remaining_budget, 2),
        logged_at: DateTime.utc_now()
      })

      {:ok, %{campaign_id: campaign_id, new_daily_cap: Float.round(adjusted_cap, 2), days_remaining: days_remaining}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def pause_overspending_campaigns do
    with {:ok, active_campaigns} <- Campaign.list_active() do
      results =
        Enum.map(active_campaigns, fn campaign ->
          case SpendRecord.today_for_campaign(campaign.id) do
            {:ok, today_spend} ->
              if today_spend.total > campaign.daily_cap * @overspend_threshold_pct do
                case pause_campaign(campaign.id, :daily_cap_exceeded) do
                  {:ok, _} ->
                    {:paused, campaign.id}
                    {:ok, _} = PacingAlert.create(%{
                      campaign_id: campaign.id,
                      alert_type: :overspend_pause,
                      spend: today_spend.total,
                      cap: campaign.daily_cap,
                      triggered_at: DateTime.utc_now()
                    })
                  error -> {:error, campaign.id, error}
                end
              else
                {:ok, campaign.id}
              end
            _ -> {:skip, campaign.id}
          end
        end)

      paused = Enum.count(results, &match?({:paused, _}, &1))
      {:ok, %{checked: length(active_campaigns), paused: paused}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def reallocate_budget(campaign_id, line_item_allocations) do
    with {:ok, campaign} <- Campaign.get(campaign_id),
         :ok <- validate_campaign_active(campaign),
         {:ok, line_items} <- LineItem.list_for_campaign(campaign_id) do

      total_allocated = Enum.sum(Enum.map(line_item_allocations, & &1.budget))

      if abs(total_allocated - campaign.total_budget) > 0.01 do
        {:error, :allocation_does_not_match_total_budget}
      else
        Enum.each(line_item_allocations, fn alloc ->
          {:ok, _} = LineItem.update(alloc.line_item_id, %{
            budget: alloc.budget,
            daily_cap: alloc.daily_cap,
            updated_at: DateTime.utc_now()
          })
        end)

        {:ok, _} = AuditLog.record(:budget_reallocated, campaign_id, %{allocations: line_item_allocations})
        {:ok, :reallocated}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def pause_campaign(campaign_id, reason) do
    with {:ok, campaign} <- Campaign.get(campaign_id),
         :ok <- validate_campaign_active(campaign) do

      {:ok, _} = Campaign.update(campaign_id, %{
        status: :paused,
        paused_at: DateTime.utc_now(),
        pause_reason: reason
      })

      {:ok, :paused}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def resume_campaign(campaign_id) do
    with {:ok, campaign} <- Campaign.get(campaign_id),
         :ok <- validate_campaign_paused(campaign),
         :ok <- validate_campaign_has_remaining_budget(campaign) do

      {:ok, _} = Campaign.update(campaign_id, %{
        status: :active,
        resumed_at: DateTime.utc_now(),
        pause_reason: nil
      })

      {:ok, :resumed}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp pacing_multiplier(campaign) do
    case campaign.pacing_strategy do
      :even -> 1.0
      :front_loaded -> 1.2
      :back_loaded -> 0.85
      _ -> 1.0
    end
  end

  defp validate_campaign_active(%{status: :active}), do: :ok
  defp validate_campaign_active(%{status: :paused}), do: {:error, :campaign_paused}
  defp validate_campaign_active(%{status: :completed}), do: {:error, :campaign_completed}
  defp validate_campaign_active(_), do: {:error, :campaign_not_active}

  defp validate_campaign_paused(%{status: :paused}), do: :ok
  defp validate_campaign_paused(_), do: {:error, :campaign_not_paused}

  defp validate_campaign_has_remaining_budget(campaign) do
    case SpendRecord.total_for_campaign(campaign.id) do
      {:ok, spend} ->
        if spend.total < campaign.total_budget, do: :ok, else: {:error, :budget_exhausted}
      error -> error
    end
  end
end
```
