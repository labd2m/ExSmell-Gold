```elixir
defmodule MyApp.Catalogue.BulkPriceUpdater do
  @moduledoc """
  Applies bulk price changes to a set of products in a single database
  operation. Price changes are validated before any writes occur; if any
  change is invalid the entire batch is rejected with per-product error
  details. Successful batches emit a telemetry event and write an audit
  record per changed product.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias MyApp.Catalogue.{Product, PriceHistory}
  alias MyApp.Compliance.AuditLogger

  @max_batch_size 500
  @max_price_increase_bps 30_000

  @type price_change :: %{
          required(:product_id) => String.t(),
          required(:new_price_cents) => pos_integer(),
          optional(:reason) => String.t()
        }

  @type update_result :: %{
          updated: non_neg_integer(),
          skipped: non_neg_integer(),
          errors: [%{product_id: String.t(), reason: String.t()}]
        }

  @doc """
  Validates and applies `price_changes` as a batch. The batch is
  rejected if it exceeds `#{@max_batch_size}` items or if any change
  fails validation. Returns an `{:ok, result}` summary on success.
  """
  @spec apply(String.t(), [price_change()]) ::
          {:ok, update_result()} | {:error, :batch_too_large} | {:error, [map()]}
  def apply(actor_id, price_changes)
      when is_binary(actor_id) and is_list(price_changes) do
    if length(price_changes) > @max_batch_size do
      {:error, :batch_too_large}
    else
      case validate_batch(price_changes) do
        [] -> execute_batch(actor_id, price_changes)
        errors -> {:error, errors}
      end
    end
  end

  @spec validate_batch([price_change()]) :: [map()]
  defp validate_batch(changes) do
    product_ids = Enum.map(changes, & &1.product_id)
    existing = fetch_existing_prices(product_ids)

    Enum.flat_map(changes, fn change ->
      validate_change(change, Map.get(existing, change.product_id))
    end)
  end

  @spec validate_change(price_change(), pos_integer() | nil) :: [map()]
  defp validate_change(%{product_id: id}, nil) do
    [%{product_id: id, reason: "product not found"}]
  end

  defp validate_change(%{product_id: id, new_price_cents: new_price}, current_price) do
    increase_bps = round((new_price - current_price) / current_price * 10_000)

    cond do
      new_price <= 0 ->
        [%{product_id: id, reason: "price must be positive"}]

      increase_bps > @max_price_increase_bps ->
        pct = increase_bps / 100
        [%{product_id: id, reason: "price increase of #{pct}% exceeds maximum allowed"}]

      true ->
        []
    end
  end

  @spec execute_batch(String.t(), [price_change()]) :: {:ok, update_result()}
  defp execute_batch(actor_id, changes) do
    Repo.transaction(fn ->
      {updated, skipped} =
        Enum.reduce(changes, {0, 0}, fn change, {u, s} ->
          case update_product_price(actor_id, change) do
            :updated -> {u + 1, s}
            :skipped -> {u, s + 1}
          end
        end)

      %{updated: updated, skipped: skipped, errors: []}
    end)
    |> case do
      {:ok, result} ->
        emit_telemetry(result)
        {:ok, result}

      {:error, reason} ->
        {:error, [%{product_id: "batch", reason: inspect(reason)}]}
    end
  end

  @spec update_product_price(String.t(), price_change()) :: :updated | :skipped
  defp update_product_price(actor_id, change) do
    case Repo.get(Product, change.product_id) do
      nil ->
        :skipped

      product ->
        if product.price_cents != change.new_price_cents do
          PriceHistory.record_change(product.id, change.new_price_cents, actor_id, Map.get(change, :reason))
          AuditLogger.log(%{id: actor_id, type: :user}, "product.price_changed",
            %{id: product.id, type: "product"}, %{old_price: product.price_cents, new_price: change.new_price_cents})
          :updated
        else
          :skipped
        end
    end
  end

  @spec fetch_existing_prices([String.t()]) :: %{String.t() => pos_integer()}
  defp fetch_existing_prices(product_ids) do
    Product
    |> where([p], p.id in ^product_ids)
    |> select([p], {p.id, p.price_cents})
    |> Repo.all()
    |> Map.new()
  end

  @spec emit_telemetry(update_result()) :: :ok
  defp emit_telemetry(result) do
    :telemetry.execute(
      [:my_app, :catalogue, :bulk_price_update],
      %{updated: result.updated, skipped: result.skipped},
      %{}
    )
  end
end
```
