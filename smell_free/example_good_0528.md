```elixir
defmodule Inventory.LotTracker do
  @moduledoc """
  Tracks inventory lots — discrete batches of received stock with their
  own expiry dates and supplier references. Lot allocation follows FEFO
  (first-expiry, first-out) to minimise waste. The tracker is a pure
  context module backed by Ecto; no GenServer is involved because lot
  mutations are infrequent and require transactional safety.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias Inventory.{Lot, LotAllocation}

  @type sku :: String.t()
  @type lot_id :: Ecto.UUID.t()
  @type quantity :: pos_integer()

  @doc "Creates a new inventory lot for `sku` from a received purchase order."
  @spec receive_lot(sku(), quantity(), Date.t(), String.t()) ::
          {:ok, Lot.t()} | {:error, Ecto.Changeset.t()}
  def receive_lot(sku, quantity, expiry_date, supplier_ref)
      when is_binary(sku) and is_integer(quantity) and quantity > 0 do
    %Lot{}
    |> Lot.changeset(%{sku: sku, quantity: quantity, remaining: quantity,
                       expiry_date: expiry_date, supplier_ref: supplier_ref})
    |> Repo.insert()
  end

  @doc """
  Allocates `quantity` units of `sku` using FEFO ordering. Creates
  allocation records spanning multiple lots if needed. Returns
  `{:error, :insufficient_stock}` when available quantity is below demand.
  """
  @spec allocate(sku(), quantity(), String.t()) ::
          {:ok, [LotAllocation.t()]} | {:error, :insufficient_stock | Ecto.Changeset.t()}
  def allocate(sku, quantity, order_id)
      when is_binary(sku) and is_integer(quantity) and quantity > 0 do
    Repo.transaction(fn ->
      lots = available_lots_fefo(sku)
      total_available = Enum.sum_by(lots, & &1.remaining)

      if total_available < quantity do
        Repo.rollback(:insufficient_stock)
      else
        allocate_from_lots(lots, quantity, order_id)
      end
    end)
  end

  @doc "Returns all lots for `sku` with remaining stock, ordered by expiry date ascending."
  @spec available_lots(sku()) :: [Lot.t()]
  def available_lots(sku) when is_binary(sku) do
    available_lots_fefo(sku)
  end

  @doc "Returns the total available quantity for `sku` across all active lots."
  @spec available_quantity(sku()) :: non_neg_integer()
  def available_quantity(sku) when is_binary(sku) do
    from(l in Lot,
      where: l.sku == ^sku and l.remaining > 0 and l.expiry_date >= ^Date.utc_today(),
      select: sum(l.remaining)
    )
    |> Repo.one()
    |> Kernel.||(0)
  end

  defp available_lots_fefo(sku) do
    today = Date.utc_today()
    from(l in Lot,
      where: l.sku == ^sku and l.remaining > 0 and l.expiry_date >= ^today,
      order_by: [asc: l.expiry_date, asc: l.inserted_at]
    )
    |> Repo.all()
  end

  defp allocate_from_lots(lots, remaining_demand, order_id) do
    {allocations, _} =
      Enum.reduce_while(lots, {[], remaining_demand}, fn lot, {acc, demand} ->
        if demand <= 0 do
          {:halt, {acc, 0}}
        else
          taken = min(lot.remaining, demand)
          {:ok, allocation} = create_allocation(lot, taken, order_id)
          Repo.update!(Lot.deduct_changeset(lot, taken))
          {:cont, {[allocation | acc], demand - taken}}
        end
      end)

    Enum.reverse(allocations)
  end

  defp create_allocation(lot, quantity, order_id) do
    %LotAllocation{}
    |> LotAllocation.changeset(%{lot_id: lot.id, quantity: quantity, order_id: order_id})
    |> Repo.insert()
  end
end
```
