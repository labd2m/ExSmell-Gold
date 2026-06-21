```elixir
defmodule Catalog.BulkOperations do
  @moduledoc """
  Provides atomic bulk mutation operations for the product catalog.
  Every operation either succeeds completely or rolls back entirely,
  with a per-item result map describing each outcome so callers can
  report partial successes accurately in admin UIs.
  All inputs are validated before any database writes begin.
  """

  alias Catalog.{Price, Product, Repo}
  alias Ecto.Multi

  @type product_id :: binary()
  @type bulk_result :: %{
          succeeded: [product_id()],
          failed: [%{id: product_id(), reason: term()}],
          total: non_neg_integer()
        }

  @doc """
  Publishes all products in `product_ids` in a single transaction.
  Already-published products are skipped without error.
  Returns a `bulk_result()` map.
  """
  @spec bulk_publish([product_id()]) :: {:ok, bulk_result()} | {:error, term()}
  def bulk_publish(product_ids) when is_list(product_ids) do
    with {:ok, products} <- fetch_all(product_ids) do
      multi = build_publish_multi(products)

      case Repo.transaction(multi) do
        {:ok, results} -> {:ok, summarize(results, product_ids)}
        {:error, step, reason, _} -> {:error, {step, reason}}
      end
    end
  end

  @doc """
  Applies a percentage price adjustment to all products in `product_ids`.
  `factor` is a multiplier, e.g. `0.9` for 10% off or `1.15` for 15% up.
  Prices are rounded to the nearest cent.
  """
  @spec bulk_adjust_price([product_id()], float()) ::
          {:ok, bulk_result()} | {:error, term()}
  def bulk_adjust_price(product_ids, factor)
      when is_list(product_ids) and is_float(factor) and factor > 0 do
    with {:ok, products} <- fetch_all(product_ids) do
      multi = build_price_multi(products, factor)

      case Repo.transaction(multi) do
        {:ok, results} -> {:ok, summarize(results, product_ids)}
        {:error, step, reason, _} -> {:error, {step, reason}}
      end
    end
  end

  @doc """
  Archives all products in `product_ids`, removing them from public listings.
  Returns a `bulk_result()` map.
  """
  @spec bulk_archive([product_id()]) :: {:ok, bulk_result()} | {:error, term()}
  def bulk_archive(product_ids) when is_list(product_ids) do
    with {:ok, products} <- fetch_all(product_ids) do
      multi = build_archive_multi(products)

      case Repo.transaction(multi) do
        {:ok, results} -> {:ok, summarize(results, product_ids)}
        {:error, step, reason, _} -> {:error, {step, reason}}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp fetch_all(product_ids) do
    found = Repo.all(from(p in Product, where: p.id in ^product_ids))
    found_ids = Enum.map(found, & &1.id)
    missing = Enum.reject(product_ids, &(&1 in found_ids))

    if missing == [] do
      {:ok, found}
    else
      {:error, {:products_not_found, missing}}
    end
  end

  defp build_publish_multi(products) do
    Enum.reduce(products, Multi.new(), fn product, multi ->
      changeset = Product.publish_changeset(product)
      Multi.update(multi, {:publish, product.id}, changeset)
    end)
  end

  defp build_price_multi(products, factor) do
    Enum.reduce(products, Multi.new(), fn product, multi ->
      new_price = round(product.price_cents * factor)
      changeset = Price.adjustment_changeset(product, %{price_cents: new_price})
      Multi.update(multi, {:price, product.id}, changeset)
    end)
  end

  defp build_archive_multi(products) do
    Enum.reduce(products, Multi.new(), fn product, multi ->
      changeset = Product.archive_changeset(product)
      Multi.update(multi, {:archive, product.id}, changeset)
    end)
  end

  defp summarize(results, requested_ids) do
    succeeded =
      results
      |> Map.values()
      |> Enum.filter(&is_struct(&1, Product))
      |> Enum.map(& &1.id)

    failed =
      Enum.flat_map(requested_ids, fn id ->
        if id in succeeded, do: [], else: [%{id: id, reason: :unchanged}]
      end)

    %{succeeded: succeeded, failed: failed, total: length(requested_ids)}
  end
end
```
