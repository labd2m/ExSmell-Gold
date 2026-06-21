# File: `example_good_419.md`

```elixir
defmodule Catalog.PriceList do
  @moduledoc """
  Manages customer-specific and segment-specific price lists that
  override catalogue base prices.

  Price resolution follows a priority chain: customer-specific price →
  segment price → base price. Each tier is checked in order and the
  first match wins.
  """

  import Ecto.Query, warn: false

  alias Catalog.{Price, PriceOverride, Product, Repo}

  @type customer_id :: String.t()
  @type segment :: atom()
  @type sku :: String.t()
  @type amount_cents :: non_neg_integer()

  @type price_result :: %{
          sku: sku(),
          amount_cents: amount_cents(),
          currency: String.t(),
          source: :customer | :segment | :base
        }

  @doc """
  Resolves the effective price for a SKU, given an optional customer ID
  and segment.

  Priority: customer override > segment override > base catalogue price.
  Returns `{:error, :not_found}` when the SKU has no price at any tier.
  """
  @spec resolve(sku(), customer_id() | nil, segment() | nil) ::
          {:ok, price_result()} | {:error, :not_found}
  def resolve(sku, customer_id \\ nil, segment \\ nil) when is_binary(sku) do
    resolve_tiers(sku, customer_id, segment)
  end

  @doc """
  Resolves effective prices for a list of SKUs in a single query pass.

  Returns a map of SKU to price result for all resolved SKUs.
  SKUs with no price at any tier are omitted from the result.
  """
  @spec resolve_many([sku()], customer_id() | nil, segment() | nil) ::
          %{sku() => price_result()}
  def resolve_many(skus, customer_id \\ nil, segment \\ nil)
      when is_list(skus) do
    overrides = fetch_all_overrides(skus, customer_id, segment)
    base_prices = fetch_base_prices(skus)

    Map.new(skus, fn sku ->
      result = pick_price(sku, overrides, base_prices, segment)
      {sku, result}
    end)
    |> Map.reject(fn {_sku, v} -> is_nil(v) end)
  end

  @doc """
  Sets a customer-specific price override for a SKU.

  Returns `{:ok, override}` or `{:error, changeset}`.
  """
  @spec set_customer_price(customer_id(), sku(), amount_cents(), String.t()) ::
          {:ok, PriceOverride.t()} | {:error, Ecto.Changeset.t()}
  def set_customer_price(customer_id, sku, amount_cents, currency) do
    upsert_override(%{
      scope: :customer,
      scope_id: customer_id,
      sku: sku,
      amount_cents: amount_cents,
      currency: currency
    })
  end

  @doc """
  Sets a segment-level price override for a SKU.
  """
  @spec set_segment_price(segment(), sku(), amount_cents(), String.t()) ::
          {:ok, PriceOverride.t()} | {:error, Ecto.Changeset.t()}
  def set_segment_price(segment, sku, amount_cents, currency)
      when is_atom(segment) do
    upsert_override(%{
      scope: :segment,
      scope_id: Atom.to_string(segment),
      sku: sku,
      amount_cents: amount_cents,
      currency: currency
    })
  end

  @doc """
  Removes all price overrides for a customer.
  """
  @spec clear_customer_prices(customer_id()) :: {non_neg_integer(), nil}
  def clear_customer_prices(customer_id) when is_binary(customer_id) do
    PriceOverride
    |> where([o], o.scope == :customer and o.scope_id == ^customer_id)
    |> Repo.delete_all()
  end

  defp resolve_tiers(sku, customer_id, segment) do
    with nil <- find_customer_override(sku, customer_id),
         nil <- find_segment_override(sku, segment),
         nil <- find_base_price(sku) do
      {:error, :not_found}
    else
      result -> {:ok, result}
    end
  end

  defp find_customer_override(_sku, nil), do: nil

  defp find_customer_override(sku, customer_id) do
    PriceOverride
    |> where([o], o.sku == ^sku and o.scope == :customer and o.scope_id == ^customer_id)
    |> Repo.one()
    |> to_price_result(:customer)
  end

  defp find_segment_override(_sku, nil), do: nil

  defp find_segment_override(sku, segment) do
    scope_id = Atom.to_string(segment)

    PriceOverride
    |> where([o], o.sku == ^sku and o.scope == :segment and o.scope_id == ^scope_id)
    |> Repo.one()
    |> to_price_result(:segment)
  end

  defp find_base_price(sku) do
    Price
    |> where([p], p.sku == ^sku)
    |> Repo.one()
    |> to_price_result(:base)
  end

  defp to_price_result(nil, _source), do: nil

  defp to_price_result(record, source) do
    %{sku: record.sku, amount_cents: record.amount_cents, currency: record.currency, source: source}
  end

  defp fetch_all_overrides(skus, customer_id, segment) do
    scope_ids = Enum.reject([customer_id, segment && Atom.to_string(segment)], &is_nil/1)

    PriceOverride
    |> where([o], o.sku in ^skus and o.scope_id in ^scope_ids)
    |> Repo.all()
  end

  defp fetch_base_prices(skus) do
    Price
    |> where([p], p.sku in ^skus)
    |> Repo.all()
    |> Map.new(&{&1.sku, &1})
  end

  defp pick_price(sku, overrides, base_prices, segment) do
    customer_match = Enum.find(overrides, &(&1.sku == sku and &1.scope == :customer))
    segment_match = segment && Enum.find(overrides, &(&1.sku == sku and &1.scope == :segment))

    cond do
      customer_match -> to_price_result(customer_match, :customer)
      segment_match -> to_price_result(segment_match, :segment)
      Map.has_key?(base_prices, sku) -> to_price_result(base_prices[sku], :base)
      true -> nil
    end
  end

  defp upsert_override(attrs) do
    attrs
    |> PriceOverride.changeset()
    |> Repo.insert(on_conflict: :replace_all, conflict_target: [:scope, :scope_id, :sku])
  end
end
```
