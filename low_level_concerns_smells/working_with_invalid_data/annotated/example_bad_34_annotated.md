# Code Smell Annotation

- **Smell name:** Working with invalid data
- **Expected smell location:** `BudgetAllocator.distribute/3`, where `total_budget` is used in division to compute channel shares
- **Affected function(s):** `distribute/3`
- **Short explanation:** The `total_budget` parameter is used directly in a division expression (`total_budget * weight`) without any type check at the function boundary. Marketing budget values often flow from spreadsheet imports or admin interfaces where they may arrive as strings. Passing `"50000"` causes an `ArithmeticError` inside the multiplication, pointing at a private helper rather than the `distribute/3` entry point.

```elixir
defmodule MyApp.Marketing.BudgetAllocator do
  @moduledoc """
  Distributes marketing budgets across channels and campaigns based on
  performance weights, historical ROI, and strategic allocation rules.
  """

  require Logger

  alias MyApp.Marketing.{CampaignRecord, ChannelPerformance, AllocationLog, ROITracker}

  @supported_channels [:paid_search, :social, :display, :email, :content, :affiliate]
  @min_channel_budget 100.0
  @rounding_precision 2
  @reallocation_threshold 0.15

  @type allocation_opts :: [
          strategy: :equal | :roi_weighted | :manual,
          manual_weights: map(),
          reserve_percent: number(),
          lock_channels: [atom()]
        ]

  @spec distribute(String.t(), term(), allocation_opts()) ::
          {:ok, map()} | {:error, atom()}
  def distribute(campaign_id, total_budget, opts \\ []) do
    strategy = Keyword.get(opts, :strategy, :roi_weighted)
    reserve_percent = Keyword.get(opts, :reserve_percent, 0.05)
    lock_channels = Keyword.get(opts, :lock_channels, [])
    manual_weights = Keyword.get(opts, :manual_weights, %{})

    with {:ok, campaign} <- CampaignRecord.fetch(campaign_id),
         :ok <- validate_strategy(strategy),
         {:ok, weights} <- resolve_weights(strategy, campaign, manual_weights) do

      # VALIDATION: SMELL START - Working with invalid data
      # VALIDATION: This is a smell because `total_budget` is used in arithmetic
      # VALIDATION: (`total_budget * (1 - reserve_percent)`) without type validation.
      # VALIDATION: Budget values entered via admin UIs or spreadsheet imports
      # VALIDATION: often arrive as strings. Passing "50000" causes an ArithmeticError
      # VALIDATION: inside the multiplication expression with no pointer back to
      # VALIDATION: the `distribute/3` boundary where the invalid data was accepted.
      spendable = Float.round(total_budget * (1 - reserve_percent), @rounding_precision)
      reserve = Float.round(total_budget - spendable, @rounding_precision)
      # VALIDATION: SMELL END

      unlocked_weights =
        weights
        |> Map.drop(lock_channels)
        |> normalize_weights()

      allocations =
        Enum.map(unlocked_weights, fn {channel, weight} ->
          raw_amount = Float.round(spendable * weight, @rounding_precision)
          amount = max(raw_amount, @min_channel_budget)
          {channel, amount}
        end)
        |> Map.new()

      locked_allocations =
        Map.take(campaign.current_allocations || %{}, lock_channels)

      final_allocations = Map.merge(allocations, locked_allocations)

      total_allocated =
        final_allocations
        |> Map.values()
        |> Enum.sum()
        |> Float.round(@rounding_precision)

      result = %{
        campaign_id: campaign_id,
        total_budget: total_budget,
        spendable: spendable,
        reserve: reserve,
        allocations: final_allocations,
        total_allocated: total_allocated,
        strategy: strategy,
        allocated_at: DateTime.utc_now()
      }

      with {:ok, _} <- AllocationLog.record(result),
           {:ok, _} <- CampaignRecord.update_allocations(campaign_id, final_allocations) do
        Logger.info(
          "Budget distributed: campaign=#{campaign_id} total=#{total_budget} " <>
            "channels=#{map_size(final_allocations)}"
        )

        {:ok, result}
      end
    end
  end

  @spec reallocate_underperforming(String.t()) :: {:ok, map()} | {:error, atom()}
  def reallocate_underperforming(campaign_id) do
    with {:ok, performance} <- ChannelPerformance.fetch_current(campaign_id),
         {:ok, campaign} <- CampaignRecord.fetch(campaign_id) do
      underperforming =
        Enum.filter(performance.channels, fn {_ch, perf} ->
          perf.roi < performance.average_roi * (1 - @reallocation_threshold)
        end)
        |> Enum.map(&elem(&1, 0))

      if Enum.empty?(underperforming) do
        {:ok, %{campaign_id: campaign_id, changes: 0}}
      else
        distribute(campaign_id, campaign.total_budget,
          strategy: :roi_weighted,
          lock_channels: @supported_channels -- underperforming
        )
      end
    end
  end

  @spec pacing_report(String.t()) :: {:ok, map()} | {:error, atom()}
  def pacing_report(campaign_id) do
    with {:ok, campaign} <- CampaignRecord.fetch(campaign_id),
         {:ok, spend} <- ROITracker.total_spend(campaign_id) do
      days_elapsed = Date.diff(Date.utc_today(), campaign.start_date)
      days_total = Date.diff(campaign.end_date, campaign.start_date)
      expected_spend = campaign.total_budget * (days_elapsed / max(days_total, 1))

      {:ok,
       %{
         campaign_id: campaign_id,
         actual_spend: spend,
         expected_spend: Float.round(expected_spend, @rounding_precision),
         pacing: if(spend >= expected_spend * 0.9, do: :on_pace, else: :underpacing)
       }}
    end
  end

  # Private helpers

  defp validate_strategy(s) when s in [:equal, :roi_weighted, :manual], do: :ok
  defp validate_strategy(_), do: {:error, :invalid_strategy}

  defp resolve_weights(:equal, _campaign, _manual) do
    equal_weight = 1.0 / length(@supported_channels)
    {:ok, Map.new(@supported_channels, &{&1, equal_weight})}
  end

  defp resolve_weights(:roi_weighted, campaign, _manual) do
    ChannelPerformance.roi_weights(campaign.id)
  end

  defp resolve_weights(:manual, _campaign, manual) when map_size(manual) > 0 do
    {:ok, manual}
  end

  defp resolve_weights(:manual, _campaign, _), do: {:error, :missing_manual_weights}

  defp normalize_weights(weights) do
    total = weights |> Map.values() |> Enum.sum()
    if total == 0, do: weights, else: Map.new(weights, fn {k, v} -> {k, v / total} end)
  end
end
```
