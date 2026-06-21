```elixir
defmodule Warehouse.Inventory do
  @moduledoc """
  Context for managing stock-keeping units (SKUs), warehouse locations,
  and real-time quantity adjustments. All quantity mutations are recorded
  as immutable ledger entries to support full audit trails.
  """

  alias Warehouse.{Adjustment, Location, Repo, SKU, StockLevel}
  alias Ecto.Multi
  import Ecto.Query

  @type adjustment_reason :: :received | :shipped | :damaged | :counted | :returned
  @type quantity_opts :: [location_id: binary(), as_of: DateTime.t()]

  # ---------------------------------------------------------------------------
  # SKU queries
  # ---------------------------------------------------------------------------

  @doc """
  Fetches an active SKU by its code. Returns `{:error, :not_found}` when
  the code does not correspond to any active product.
  """
  @spec fetch_sku(binary()) :: {:ok, SKU.t()} | {:error, :not_found}
  def fetch_sku(code) when is_binary(code) do
    case Repo.get_by(SKU, code: code, archived: false) do
      nil -> {:error, :not_found}
      sku -> {:ok, sku}
    end
  end

  @doc """
  Lists all SKUs that are below their configured reorder threshold.
  Optionally scoped to a specific location via `:location_id`.
  """
  @spec list_below_reorder(quantity_opts()) :: [%{sku: SKU.t(), on_hand: integer()}]
  def list_below_reorder(opts \\ []) do
    location_filter = Keyword.get(opts, :location_id)

    StockLevel
    |> join(:inner, [sl], s in SKU, on: sl.sku_id == s.id)
    |> maybe_filter_location(location_filter)
    |> where([sl, s], sl.quantity <= s.reorder_threshold)
    |> select([sl, s], %{sku: s, on_hand: sl.quantity})
    |> Repo.all()
  end

  # ---------------------------------------------------------------------------
  # Quantity adjustments
  # ---------------------------------------------------------------------------

  @doc """
  Records a quantity adjustment for a SKU at a specific location.
  Adjustments are signed integers: positive for inbound stock, negative
  for outbound. The stock level and ledger entry are updated atomically.
  Returns `{:ok, adjustment}` or `{:error, reason}`.
  """
  @spec adjust(binary(), binary(), integer(), adjustment_reason(), binary()) ::
          {:ok, Adjustment.t()} | {:error, term()}
  def adjust(sku_id, location_id, delta, reason, operator_id)
      when is_binary(sku_id) and is_binary(location_id) and is_integer(delta) and
             is_atom(reason) and is_binary(operator_id) do
    with {:ok, location} <- fetch_location(location_id),
         {:ok, sku} <- fetch_sku_by_id(sku_id),
         :ok <- validate_delta(delta, reason) do
      commit_adjustment(sku, location, delta, reason, operator_id)
    end
  end

  @doc """
  Returns the current on-hand quantity for a SKU across all locations,
  or scoped to a specific location when `:location_id` is provided.
  """
  @spec on_hand_quantity(binary(), quantity_opts()) :: {:ok, integer()} | {:error, :not_found}
  def on_hand_quantity(sku_id, opts \\ []) when is_binary(sku_id) do
    location_id = Keyword.get(opts, :location_id)

    result =
      StockLevel
      |> where([sl], sl.sku_id == ^sku_id)
      |> maybe_filter_location(location_id)
      |> select([sl], sum(sl.quantity))
      |> Repo.one()

    case result do
      nil -> {:error, :not_found}
      total -> {:ok, total || 0}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp fetch_location(location_id) do
    case Repo.get(Location, location_id) do
      nil -> {:error, :location_not_found}
      location -> {:ok, location}
    end
  end

  defp fetch_sku_by_id(sku_id) do
    case Repo.get(SKU, sku_id) do
      nil -> {:error, :sku_not_found}
      sku -> {:ok, sku}
    end
  end

  defp validate_delta(delta, :shipped) when delta > 0, do: {:error, :shipment_must_be_negative}
  defp validate_delta(delta, :received) when delta < 0, do: {:error, :receipt_must_be_positive}
  defp validate_delta(0, _reason), do: {:error, :zero_adjustment}
  defp validate_delta(_delta, _reason), do: :ok

  defp commit_adjustment(sku, location, delta, reason, operator_id) do
    Multi.new()
    |> Multi.insert(:adjustment, build_adjustment(sku, location, delta, reason, operator_id))
    |> Multi.insert_or_update(:stock_level, upsert_stock_level(sku, location, delta))
    |> Repo.transaction()
    |> case do
      {:ok, %{adjustment: adj}} -> {:ok, adj}
      {:error, _step, reason, _} -> {:error, reason}
    end
  end

  defp build_adjustment(sku, location, delta, reason, operator_id) do
    Adjustment.changeset(%Adjustment{}, %{
      sku_id: sku.id,
      location_id: location.id,
      delta: delta,
      reason: reason,
      operator_id: operator_id
    })
  end

  defp upsert_stock_level(sku, location, delta) do
    StockLevel.upsert_changeset(%StockLevel{}, %{
      sku_id: sku.id,
      location_id: location.id,
      quantity_delta: delta
    })
  end

  defp maybe_filter_location(query, nil), do: query
  defp maybe_filter_location(query, location_id), do: where(query, [sl], sl.location_id == ^location_id)
end
```
