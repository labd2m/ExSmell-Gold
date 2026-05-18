# Annotated Example – Unnecessary Macros

| Field | Value |
|---|---|
| **Smell name** | Unnecessary macros |
| **Expected smell location** | `Logistics.FulfillmentPriority` module, `priority_score/1` macro |
| **Affected function(s)** | `priority_score/1` |
| **Short explanation** | `priority_score/1` computes a numeric priority score from fields of a runtime order map. Every field access and arithmetic operation occurs at runtime; the macro offers no compile-time expansion. A regular function would be idiomatic, composable, and callable without a `require` directive. |

```elixir
defmodule Logistics.FulfillmentPriority do
  @moduledoc """
  Ranks warehouse orders by fulfillment priority so that picking teams
  process the most time-sensitive shipments first. Factors include
  shipping speed, order age, customer tier, and inventory availability.
  """

  @tier_weights %{platinum: 40, gold: 25, silver: 10, standard: 0}
  @speed_weights %{same_day: 50, next_day: 30, express: 15, standard: 0}
  @max_age_bonus 20

  # VALIDATION: SMELL START - Unnecessary macros
  # VALIDATION: This is a smell because `priority_score/1` receives a
  # runtime order map and computes an integer by summing weighted values
  # from its fields. Every `Map.get/2`, arithmetic operation, and
  # `DateTime.diff/3` call happens at runtime. Wrapping this logic in a
  # `defmacro` with `quote/unquote` adds complexity and forces callers to
  # `require` the module — both unnecessary costs when a plain `def`
  # function would work identically.
  defmacro priority_score(order) do
    quote do
      o = unquote(order)

      tier_bonus  = Map.get(unquote(@tier_weights),  Map.get(o, :customer_tier,  :standard), 0)
      speed_bonus = Map.get(unquote(@speed_weights), Map.get(o, :shipping_speed, :standard), 0)

      age_seconds = DateTime.diff(DateTime.utc_now(), Map.get(o, :placed_at, DateTime.utc_now()))
      age_bonus   = min(div(age_seconds, 3_600), unquote(@max_age_bonus))

      backordered_penalty = if Map.get(o, :has_backorder, false), do: -30, else: 0

      tier_bonus + speed_bonus + age_bonus + backordered_penalty
    end
  end
  # VALIDATION: SMELL END

  def rank(orders) do
    require Logistics.FulfillmentPriority

    orders
    |> Enum.map(fn order ->
      score = Logistics.FulfillmentPriority.priority_score(order)
      Map.put(order, :priority_score, score)
    end)
    |> Enum.sort_by(& &1.priority_score, :desc)
  end

  def top_n(orders, n) do
    orders |> rank() |> Enum.take(n)
  end

  def assign_to_picker(orders, pickers) do
    ranked = rank(orders)
    picker_count = length(pickers)

    ranked
    |> Enum.with_index()
    |> Enum.map(fn {order, idx} ->
      picker = Enum.at(pickers, rem(idx, picker_count))
      Map.put(order, :assigned_picker, picker.id)
    end)
  end

  def flag_urgent(orders, threshold \\ 60) do
    require Logistics.FulfillmentPriority

    Enum.filter(orders, fn order ->
      Logistics.FulfillmentPriority.priority_score(order) >= threshold
    end)
  end

  def score_summary(orders) do
    require Logistics.FulfillmentPriority

    scores = Enum.map(orders, fn o -> Logistics.FulfillmentPriority.priority_score(o) end)

    %{
      count:   length(scores),
      max:     Enum.max(scores, fn -> 0 end),
      min:     Enum.min(scores, fn -> 0 end),
      average: if(scores != [], do: Enum.sum(scores) / length(scores), else: 0.0),
      urgent:  Enum.count(scores, &(&1 >= 60))
    }
  end

  def explain_score(order) do
    tier_bonus  = Map.get(@tier_weights,  order.customer_tier,  0)
    speed_bonus = Map.get(@speed_weights, order.shipping_speed, 0)
    age_hours   = DateTime.diff(DateTime.utc_now(), order.placed_at, :second) |> div(3_600)
    age_bonus   = min(age_hours, @max_age_bonus)
    backorder   = if order.has_backorder, do: -30, else: 0

    %{
      tier_bonus:          tier_bonus,
      speed_bonus:         speed_bonus,
      age_bonus:           age_bonus,
      backordered_penalty: backorder,
      total:               tier_bonus + speed_bonus + age_bonus + backorder
    }
  end
end
```
