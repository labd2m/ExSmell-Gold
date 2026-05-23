```elixir
defmodule CRM.DealRecord do
  @moduledoc "Represents a sales deal in the CRM pipeline."

  defstruct [
    :id,
    :account_id,
    :owner_id,
    :stage,
    :amount,
    :currency,
    :entered_stage_at,
    :champion_contact_id,
    :competitors,
    :budget_confirmed,
    :close_date,
    :source,
    :deal_type
  ]

  def get!(id) do
    %__MODULE__{
      id: id,
      account_id: "ACC-720",
      owner_id: "REP-015",
      stage: :proposal,
      amount: Decimal.new("95000.00"),
      currency: "USD",
      entered_stage_at: ~U[2024-02-14 09:00:00Z],
      champion_contact_id: "CNT-801",
      competitors: ["CompetitorA", "CompetitorB"],
      budget_confirmed: true,
      close_date: ~D[2024-04-30],
      source: :inbound,
      deal_type: :new_business
    }
  end

  def deal_size_tier(%__MODULE__{amount: amount}) do
    cond do
      Decimal.gt?(amount, Decimal.new("100000")) -> :enterprise
      Decimal.gt?(amount, Decimal.new("25000"))  -> :mid_market
      true                                       -> :smb
    end
  end

  def days_in_stage(%__MODULE__{entered_stage_at: entered}) do
    DateTime.diff(DateTime.utc_now(), entered, :day)
  end

  def has_champion?(%__MODULE__{champion_contact_id: nil}), do: false
  def has_champion?(_), do: true

  def competitor_count(%__MODULE__{competitors: comps}) when is_list(comps), do: length(comps)
  def competitor_count(_), do: 0

  def budget_confirmed?(%__MODULE__{budget_confirmed: true}), do: true
  def budget_confirmed?(_), do: false

  def stage_label(%__MODULE__{stage: stage}), do: stage |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()
end

defmodule CRM.DealPipeline do
  @moduledoc """
  Manages pipeline-level operations including stage transitions,
  weighted pipeline value calculation, and probability scoring.
  """

  alias CRM.DealRecord
  require Logger

  @doc """
  Computes a weighted pipeline value for a list of deal IDs.
  Returns total value weighted by each deal's close probability.
  """
  def weighted_pipeline_value(deal_ids) do
    deal_ids
    |> Enum.map(fn id ->
      deal  = DealRecord.get!(id)
      prob  = score_deal_probability(id)
      value = Decimal.mult(deal.amount, Decimal.new(prob / 100))
      {id, Decimal.round(value, 2)}
    end)
    |> Enum.into(%{})
  end

  @doc "Transitions a deal to the next pipeline stage."
  def advance_stage(deal_id, new_stage) do
    Logger.info("Advancing deal #{deal_id} to stage #{new_stage}")
    {:ok, :advanced}
  end

  defp score_deal_probability(deal_id) do
    deal     = DealRecord.get!(deal_id)
    tier     = DealRecord.deal_size_tier(deal)
    days     = DealRecord.days_in_stage(deal)
    champion = DealRecord.has_champion?(deal)
    comps    = DealRecord.competitor_count(deal)
    budget   = DealRecord.budget_confirmed?(deal)

    base =
      case tier do
        :enterprise  -> 25
        :mid_market  -> 40
        :smb         -> 55
      end

    score =
      base
      |> then(fn s -> if champion, do: s + 15, else: s end)
      |> then(fn s -> if budget,   do: s + 10, else: s end)
      |> then(fn s -> s - comps * 5 end)
      |> then(fn s -> if days > 30, do: s - 10, else: s end)

    min(95, max(5, score))
  end
end
```
