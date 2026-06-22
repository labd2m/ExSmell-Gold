```elixir
defmodule MyApp.Ecommerce.ReorderSuggester do
  @moduledoc """
  Analyses a customer's purchase history to suggest products they should
  consider reordering. Suggestions are ranked by a composite score that
  weighs purchase recency, historical order frequency, and the average
  time between repurchases. Products already in the customer's active
  cart are excluded from suggestions.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias MyApp.Commerce.{OrderItem, Order, Cart}
  alias MyApp.Catalog.Product

  @max_suggestions 10
  @lookback_days 365
  @min_purchase_count 2

  @type customer_id :: String.t()
  @type suggestion :: %{
          product_id: String.t(),
          name: String.t(),
          price_cents: pos_integer(),
          score: float(),
          last_ordered_days_ago: non_neg_integer(),
          avg_reorder_days: float() | nil
        }

  @doc """
  Returns reorder suggestions for `customer_id`, excluding any products
  currently in the customer's active cart.
  """
  @spec suggest(customer_id(), pos_integer()) :: [suggestion()]
  def suggest(customer_id, limit \\ @max_suggestions)
      when is_binary(customer_id) and is_integer(limit) do
    cart_product_ids = fetch_cart_product_ids(customer_id)

    customer_id
    |> fetch_purchase_history()
    |> Enum.reject(fn %{product_id: pid} -> pid in cart_product_ids end)
    |> Enum.map(&score_product/1)
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(limit)
    |> hydrate_product_details()
  end

  @spec fetch_purchase_history(customer_id()) :: [map()]
  defp fetch_purchase_history(customer_id) do
    cutoff = Date.add(Date.utc_today(), -@lookback_days)

    OrderItem
    |> join(:inner, [i], o in Order,
      on: o.id == i.order_id and o.customer_id == ^customer_id and
            o.status == :completed and o.inserted_at >= ^cutoff
    )
    |> group_by([i, _o], i.product_id)
    |> select([i, o], %{
      product_id: i.product_id,
      purchase_count: count(i.id),
      last_ordered_at: max(o.inserted_at),
      first_ordered_at: min(o.inserted_at)
    })
    |> having([i, _o], count(i.id) >= @min_purchase_count)
    |> Repo.all()
  end

  @spec fetch_cart_product_ids(customer_id()) :: [String.t()]
  defp fetch_cart_product_ids(customer_id) do
    Cart
    |> join(:inner, [c], i in assoc(c, :items))
    |> where([c, _i], c.customer_id == ^customer_id and is_nil(c.converted_at))
    |> select([_c, i], i.product_id)
    |> Repo.all()
  end

  @spec score_product(map()) :: map()
  defp score_product(history) do
    days_since_last =
      history.last_ordered_at
      |> DateTime.to_date()
      |> then(&Date.diff(Date.utc_today(), &1))

    avg_days = compute_avg_reorder_days(history)
    recency_score = max(1.0 - days_since_last / 90.0, 0.0)
    frequency_score = min(history.purchase_count / 12.0, 1.0)

    due_score =
      case avg_days do
        nil -> 0.5
        avg -> min(days_since_last / avg, 2.0) / 2.0
      end

    score = Float.round(recency_score * 0.3 + frequency_score * 0.3 + due_score * 0.4, 4)

    Map.merge(history, %{
      score: score,
      last_ordered_days_ago: days_since_last,
      avg_reorder_days: avg_days
    })
  end

  @spec compute_avg_reorder_days(map()) :: float() | nil
  defp compute_avg_reorder_days(%{purchase_count: count, first_ordered_at: first, last_ordered_at: last})
       when count >= 2 do
    total_days = DateTime.diff(last, first, :day)
    Float.round(total_days / (count - 1), 1)
  end

  defp compute_avg_reorder_days(_), do: nil

  @spec hydrate_product_details([map()]) :: [suggestion()]
  defp hydrate_product_details(scored) do
    ids = Enum.map(scored, & &1.product_id)

    products =
      Product
      |> where([p], p.id in ^ids and p.active == true)
      |> select([p], {p.id, p.name, p.price_cents})
      |> Repo.all()
      |> Map.new(fn {id, name, price} -> {id, %{name: name, price_cents: price}} end)

    scored
    |> Enum.flat_map(fn item ->
      case Map.get(products, item.product_id) do
        nil -> []
        details ->
          [%{
            product_id: item.product_id,
            name: details.name,
            price_cents: details.price_cents,
            score: item.score,
            last_ordered_days_ago: item.last_ordered_days_ago,
            avg_reorder_days: item.avg_reorder_days
          }]
      end
    end)
  end
end
```
