```elixir
defmodule MyApp.Catalog.PriceHistory do
  @moduledoc """
  Maintains a complete immutable price change history for catalog products.
  Every price update writes a new `price_history_entries` record rather
  than modifying the existing one, preserving the full audit trail. The
  current price is always the most recent entry, so no additional column
  is needed on the `products` table.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias MyApp.Catalog.{Product, PriceHistoryEntry}

  @type product_id :: String.t()
  @type actor_id :: String.t()

  @doc """
  Records a price change for `product_id` from its current price to
  `new_price_cents`. Returns `{:ok, entry}` or `{:error, :no_change}`
  when the new price equals the current price.
  """
  @spec record_change(product_id(), pos_integer(), actor_id(), String.t() | nil) ::
          {:ok, PriceHistoryEntry.t()}
          | {:error, :no_change}
          | {:error, :product_not_found}
          | {:error, Ecto.Changeset.t()}
  def record_change(product_id, new_price_cents, actor_id, reason \\ nil)
      when is_binary(product_id) and is_integer(new_price_cents) and new_price_cents > 0 do
    case Repo.get(Product, product_id) do
      nil ->
        {:error, :product_not_found}

      product ->
        if product.price_cents == new_price_cents do
          {:error, :no_change}
        else
          insert_entry(product, new_price_cents, actor_id, reason)
        end
    end
  end

  @doc """
  Returns the full price history for `product_id`, newest first.
  """
  @spec for_product(product_id()) :: [PriceHistoryEntry.t()]
  def for_product(product_id) when is_binary(product_id) do
    PriceHistoryEntry
    |> where([e], e.product_id == ^product_id)
    |> order_by([e], desc: e.effective_at)
    |> Repo.all()
  end

  @doc """
  Returns the price of `product_id` as it was at `point_in_time`.
  Returns `nil` when no price record existed before that moment.
  """
  @spec price_at(product_id(), DateTime.t()) :: pos_integer() | nil
  def price_at(product_id, %DateTime{} = point_in_time) when is_binary(product_id) do
    PriceHistoryEntry
    |> where([e], e.product_id == ^product_id and e.effective_at <= ^point_in_time)
    |> order_by([e], desc: e.effective_at)
    |> limit(1)
    |> select([e], e.price_cents)
    |> Repo.one()
  end

  @doc """
  Returns aggregated price change statistics for `product_id`: the
  minimum, maximum, and average price over all recorded history.
  """
  @spec stats(product_id()) :: %{min: pos_integer(), max: pos_integer(), avg: float()} | nil
  def stats(product_id) when is_binary(product_id) do
    PriceHistoryEntry
    |> where([e], e.product_id == ^product_id)
    |> select([e], %{
      min: min(e.price_cents),
      max: max(e.price_cents),
      avg: avg(e.price_cents)
    })
    |> Repo.one()
    |> case do
      %{min: nil} -> nil
      result -> result
    end
  end

  @spec insert_entry(Product.t(), pos_integer(), actor_id(), String.t() | nil) ::
          {:ok, PriceHistoryEntry.t()} | {:error, Ecto.Changeset.t()}
  defp insert_entry(product, new_price_cents, actor_id, reason) do
    Repo.transaction(fn ->
      product
      |> Product.changeset(%{price_cents: new_price_cents})
      |> Repo.update!()

      %PriceHistoryEntry{}
      |> PriceHistoryEntry.changeset(%{
        product_id: product.id,
        previous_price_cents: product.price_cents,
        price_cents: new_price_cents,
        actor_id: actor_id,
        reason: reason,
        effective_at: DateTime.utc_now()
      })
      |> Repo.insert!()
    end)
  end
end
```
