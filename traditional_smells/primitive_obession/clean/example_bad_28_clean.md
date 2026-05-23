```elixir
defmodule Inventory.StockManager do
  @moduledoc """
  Manages stock levels across warehouse locations. Handles reservations,
  replenishments, inter-warehouse transfers, and availability queries
  for the fulfilment pipeline.
  """

  require Logger

  alias Inventory.Repo
  alias Inventory.Schema.{StockEntry, Warehouse, ReservationLedger}

  @sku_pattern ~r/^[A-Z]{2,6}-[A-Z0-9]{2,10}-\d{1,4}-[A-Z]{3}-[A-Z]{2}$/
  @low_stock_threshold 10


  @spec reserve_stock(String.t(), integer(), String.t()) ::
          {:ok, ReservationLedger.t()} | {:error, term()}
  def reserve_stock(sku, quantity, warehouse_id)
      when is_binary(sku) and is_integer(quantity) and is_binary(warehouse_id) do
    with :ok <- validate_sku_format(sku),
         {:ok, entry} <- fetch_stock_entry(sku, warehouse_id),
         :ok <- ensure_sufficient_stock(entry, quantity) do
      region = extract_sku_region(sku)
      category = extract_sku_category(sku)

      Logger.info("Reserving #{quantity} units of SKU=#{sku} (#{category}/#{region}) at warehouse=#{warehouse_id}")

      attrs = %{
        sku: sku,
        sku_category: category,
        sku_region: region,
        quantity: quantity,
        warehouse_id: warehouse_id,
        reserved_at: DateTime.utc_now(),
        expires_at: DateTime.add(DateTime.utc_now(), 900)
      }

      %ReservationLedger{} |> ReservationLedger.changeset(attrs) |> Repo.insert()
    end
  end

  @spec replenish(String.t(), integer(), String.t()) ::
          {:ok, StockEntry.t()} | {:error, term()}
  def replenish(sku, quantity, warehouse_id)
      when is_binary(sku) and is_integer(quantity) and is_binary(warehouse_id) do
    with :ok <- validate_sku_format(sku) do
      category = extract_sku_category(sku)
      region = extract_sku_region(sku)

      case Repo.get_by(StockEntry, sku: sku, warehouse_id: warehouse_id) do
        nil ->
          attrs = %{sku: sku, quantity: quantity, warehouse_id: warehouse_id,
                    category: category, region: region, last_replenished_at: DateTime.utc_now()}

          %StockEntry{} |> StockEntry.changeset(attrs) |> Repo.insert()

        entry ->
          entry
          |> StockEntry.changeset(%{
            quantity: entry.quantity + quantity,
            last_replenished_at: DateTime.utc_now()
          })
          |> Repo.update()
      end
    end
  end

  @spec transfer_between_warehouses(String.t(), integer(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def transfer_between_warehouses(sku, quantity, from_warehouse_id, to_warehouse_id)
      when is_binary(sku) and is_integer(quantity) do
    with :ok <- validate_sku_format(sku),
         {:ok, source} <- fetch_stock_entry(sku, from_warehouse_id),
         :ok <- ensure_sufficient_stock(source, quantity),
         {:ok, _deducted} <- deduct_stock(source, quantity),
         {:ok, _added} <- replenish(sku, quantity, to_warehouse_id) do
      Logger.info("Transferred #{quantity}x #{sku} from=#{from_warehouse_id} to=#{to_warehouse_id}")
      {:ok, %{sku: sku, quantity: quantity, from: from_warehouse_id, to: to_warehouse_id}}
    end
  end

  @spec lookup_product(String.t()) :: {:ok, map()} | {:error, :not_found}
  def lookup_product(sku) when is_binary(sku) do
    case Repo.get_by(StockEntry, sku: sku) do
      nil ->
        {:error, :not_found}

      entry ->
        colour = extract_sku_colour(sku)
        size = extract_sku_size(sku)
        category = extract_sku_category(sku)
        region = extract_sku_region(sku)

        {:ok, %{
          sku: sku,
          category: category,
          colour: colour,
          size: size,
          region: region,
          quantity_on_hand: entry.quantity,
          low_stock: entry.quantity < @low_stock_threshold
        }}
    end
  end


  ## Private helpers

  defp validate_sku_format(sku) do
    if Regex.match?(@sku_pattern, sku) do
      :ok
    else
      {:error, {:invalid_sku_format, sku}}
    end
  end

  defp extract_sku_category(sku), do: sku |> String.split("-") |> Enum.at(0)
  defp extract_sku_size(sku), do: sku |> String.split("-") |> Enum.at(2) |> String.to_integer()
  defp extract_sku_colour(sku), do: sku |> String.split("-") |> Enum.at(3)
  defp extract_sku_region(sku), do: sku |> String.split("-") |> Enum.at(4)

  defp fetch_stock_entry(sku, warehouse_id) do
    case Repo.get_by(StockEntry, sku: sku, warehouse_id: warehouse_id) do
      nil -> {:error, {:stock_not_found, sku, warehouse_id}}
      entry -> {:ok, entry}
    end
  end

  defp ensure_sufficient_stock(%StockEntry{quantity: qty}, needed) when qty >= needed, do: :ok
  defp ensure_sufficient_stock(%StockEntry{quantity: qty}, needed),
    do: {:error, {:insufficient_stock, needed, qty}}

  defp deduct_stock(%StockEntry{} = entry, quantity) do
    entry
    |> StockEntry.changeset(%{quantity: entry.quantity - quantity})
    |> Repo.update()
  end
end
```