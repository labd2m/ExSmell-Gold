```elixir
defmodule Warehouse.WarehouseManager do
  @moduledoc """
  Manages inbound stock receiving, outbound fulfilment, and periodic inventory audits.
  """

  alias Warehouse.Repo
  alias Warehouse.Stock.StockUnit
  alias Warehouse.Stock.Location
  alias Warehouse.Fulfilment.PickList
  alias Warehouse.Fulfilment.Parcel
  alias Warehouse.Audit.StockCount

  import Ecto.Query
  require Logger



  @doc "Receives a purchase order shipment and increments stock levels."
  @spec receive_stock(String.t(), [map()]) :: {:ok, [StockUnit.t()]} | {:error, term()}
  def receive_stock(purchase_order_id, line_items) do
    Repo.transaction(fn ->
      Enum.map(line_items, fn %{sku: sku, quantity: qty, condition: cond} ->
        existing = Repo.get_by(StockUnit, sku: sku)

        if existing do
          existing
          |> StockUnit.changeset(%{on_hand: existing.on_hand + qty})
          |> Repo.update!()
        else
          %StockUnit{}
          |> StockUnit.changeset(%{
            sku: sku,
            on_hand: qty,
            condition: cond,
            purchase_order_id: purchase_order_id
          })
          |> Repo.insert!()
        end
      end)
    end)
  end

  @doc "Records the physical bin location where a received SKU has been stored."
  @spec put_away_stock(StockUnit.t(), String.t()) ::
          {:ok, StockUnit.t()} | {:error, term()}
  def put_away_stock(%StockUnit{} = unit, bin_code) do
    location = Repo.get_by!(Location, bin_code: bin_code)

    unit
    |> StockUnit.changeset(%{location_id: location.id, put_away_at: DateTime.utc_now()})
    |> Repo.update()
  end

  @doc "Moves a quantity of a SKU between two bin locations."
  @spec move_stock(String.t(), String.t(), pos_integer()) ::
          :ok | {:error, atom()}
  def move_stock(from_bin, to_bin, quantity) do
    from_loc = Repo.get_by!(Location, bin_code: from_bin)
    to_loc = Repo.get_by!(Location, bin_code: to_bin)

    units_at_from =
      StockUnit
      |> where([s], s.location_id == ^from_loc.id)
      |> Repo.all()

    total_available = Enum.sum(Enum.map(units_at_from, & &1.on_hand))

    if total_available >= quantity do
      Logger.info("Moving #{quantity} units from #{from_bin} to #{to_bin}")
      Warehouse.Stock.Transfers.execute(from_loc, to_loc, quantity)
      :ok
    else
      {:error, :insufficient_stock}
    end
  end


  @doc "Generates a pick list for an outbound order."
  @spec pick_items(String.t(), [map()]) :: {:ok, PickList.t()} | {:error, term()}
  def pick_items(order_id, required_items) do
    picks =
      Enum.map(required_items, fn %{sku: sku, quantity: qty} ->
        unit = Repo.get_by!(StockUnit, sku: sku)
        location = Repo.get!(Location, unit.location_id)

        %{sku: sku, quantity: qty, bin_code: location.bin_code, unit_id: unit.id}
      end)

    attrs = %{order_id: order_id, picks: picks, status: :pending, created_at: DateTime.utc_now()}

    %PickList{}
    |> PickList.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Records that an order has been packed and assigns a tracking label."
  @spec pack_order(PickList.t(), map()) :: {:ok, Parcel.t()} | {:error, term()}
  def pack_order(%PickList{order_id: order_id, status: :pending} = pick_list, %{
        weight_grams: weight,
        dimensions: dims,
        carrier: carrier
      }) do
    pick_list |> PickList.changeset(%{status: :packed}) |> Repo.update!()

    label = Warehouse.Carriers.generate_label(carrier, %{weight: weight, dimensions: dims})

    attrs = %{
      order_id: order_id,
      tracking_number: label.tracking_number,
      carrier: carrier,
      weight_grams: weight,
      dimensions: dims,
      status: :ready_to_dispatch
    }

    %Parcel{} |> Parcel.changeset(attrs) |> Repo.insert()
  end

  def pack_order(%PickList{}, _), do: {:error, :pick_not_pending}

  @doc "Marks a parcel as dispatched once collected by the carrier."
  @spec dispatch_parcel(Parcel.t(), DateTime.t()) ::
          {:ok, Parcel.t()} | {:error, term()}
  def dispatch_parcel(%Parcel{status: :ready_to_dispatch} = parcel, collected_at) do
    parcel
    |> Parcel.changeset(%{status: :dispatched, dispatched_at: collected_at})
    |> Repo.update()
  end

  def dispatch_parcel(%Parcel{}, _), do: {:error, :parcel_not_ready}


  @doc "Initiates a stock count for a specific bin location."
  @spec count_inventory(String.t()) :: {:ok, StockCount.t()} | {:error, term()}
  def count_inventory(bin_code) do
    location = Repo.get_by!(Location, bin_code: bin_code)

    system_count =
      StockUnit
      |> where([s], s.location_id == ^location.id)
      |> select([s], sum(s.on_hand))
      |> Repo.one()
      |> Kernel.||(0)

    attrs = %{
      location_id: location.id,
      system_count: system_count,
      status: :pending_physical_count,
      initiated_at: DateTime.utc_now()
    }

    %StockCount{} |> StockCount.changeset(attrs) |> Repo.insert()
  end

  @doc "Reconciles a completed stock count with the system record."
  @spec reconcile_discrepancies(StockCount.t(), pos_integer()) ::
          {:ok, StockCount.t()} | {:error, term()}
  def reconcile_discrepancies(%StockCount{} = stock_count, physical_count) do
    delta = physical_count - stock_count.system_count

    stock_count
    |> StockCount.changeset(%{
      physical_count: physical_count,
      discrepancy: delta,
      status: :reconciled,
      reconciled_at: DateTime.utc_now()
    })
    |> Repo.update()
  end

  @doc "Generates a stock-level summary report across all bin locations."
  @spec generate_stock_report(atom()) :: [map()]
  def generate_stock_report(:by_sku) do
    StockUnit
    |> group_by([s], s.sku)
    |> select([s], %{sku: s.sku, total_on_hand: sum(s.on_hand), location_count: count(s.id)})
    |> Repo.all()
  end

  def generate_stock_report(:by_location) do
    StockUnit
    |> join(:inner, [s], l in Location, on: s.location_id == l.id)
    |> group_by([s, l], l.bin_code)
    |> select([s, l], %{
      bin_code: l.bin_code,
      sku_count: count(s.sku, :distinct),
      total_units: sum(s.on_hand)
    })
    |> Repo.all()
  end

end
```
