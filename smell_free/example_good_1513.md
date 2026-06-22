```elixir
defmodule Commerce.Inventory do
  @moduledoc """
  Context for managing stock levels, reservations, and product availability.

  All mutations are wrapped in database transactions and return typed result tuples.
  """

  import Ecto.Query

  alias Commerce.Repo
  alias Commerce.Inventory.{Product, StockEntry, Reservation}

  @type result(t) :: {:ok, t} | {:error, Ecto.Changeset.t() | String.t()}

  @doc """
  Returns a paginated list of products with current available stock.
  """
  @spec list_available(keyword()) :: [Product.t()]
  def list_available(opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 20)
    offset = (page - 1) * per_page

    Product
    |> join(:inner, [p], s in StockEntry, on: s.product_id == p.id)
    |> where([_, s], s.quantity_available > 0)
    |> order_by([p], asc: p.name)
    |> limit(^per_page)
    |> offset(^offset)
    |> Repo.all()
  end

  @doc """
  Atomically reserves `quantity` units of a product for an order.

  Fails if available stock is insufficient.
  """
  @spec reserve(String.t(), pos_integer(), String.t()) :: result(Reservation.t())
  def reserve(product_id, quantity, order_id)
      when is_binary(product_id) and is_integer(quantity) and quantity > 0 and is_binary(order_id) do
    Repo.transaction(fn ->
      with {:ok, entry} <- fetch_stock_entry(product_id),
           :ok <- assert_sufficient_stock(entry, quantity),
           {:ok, _entry} <- decrement_stock(entry, quantity),
           {:ok, reservation} <- create_reservation(product_id, order_id, quantity) do
        reservation
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Releases a reservation, returning units back to available stock.
  """
  @spec release(Reservation.t()) :: result(Reservation.t())
  def release(%Reservation{released_at: nil} = reservation) do
    Repo.transaction(fn ->
      with {:ok, entry} <- fetch_stock_entry(reservation.product_id),
           {:ok, _entry} <- increment_stock(entry, reservation.quantity),
           {:ok, released} <- mark_released(reservation) do
        released
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def release(%Reservation{}), do: {:error, "reservation already released"}

  # --- private helpers ---

  defp fetch_stock_entry(product_id) do
    case Repo.get_by(StockEntry, product_id: product_id) do
      nil -> {:error, "stock entry not found"}
      entry -> {:ok, entry}
    end
  end

  defp assert_sufficient_stock(%StockEntry{quantity_available: avail}, qty) when avail >= qty, do: :ok
  defp assert_sufficient_stock(_, _), do: {:error, "insufficient stock"}

  defp decrement_stock(entry, qty) do
    entry
    |> StockEntry.changeset(%{quantity_available: entry.quantity_available - qty})
    |> Repo.update()
  end

  defp increment_stock(entry, qty) do
    entry
    |> StockEntry.changeset(%{quantity_available: entry.quantity_available + qty})
    |> Repo.update()
  end

  defp create_reservation(product_id, order_id, quantity) do
    %Reservation{}
    |> Reservation.changeset(%{product_id: product_id, order_id: order_id, quantity: quantity})
    |> Repo.insert()
  end

  defp mark_released(reservation) do
    reservation
    |> Reservation.release_changeset(%{released_at: DateTime.utc_now()})
    |> Repo.update()
  end
end
```
