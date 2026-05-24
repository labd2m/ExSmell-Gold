```elixir
defmodule Inventory.StockReserver do
  @moduledoc """
  Manages stock reservations for incoming customer orders.
  Coordinates zone-level policies to determine reservation windows and auto-release behaviour.
  """

  alias Inventory.{Reservation, ReservationLedger, Repo}
  alias Products.Product
  alias Warehouses.Warehouse

  require Logger

  @buffer_multiplier 1.05
  @reservation_id_prefix "RSV"

  @spec reserve(String.t(), String.t(), pos_integer()) ::
          {:ok, Reservation.t()} | {:error, atom()}
  def reserve(order_id, product_id, requested_qty) when requested_qty > 0 do
    with {:ok, product} <- Product.fetch(product_id),
         :ok            <- ensure_product_active(product),
         :ok            <- ensure_sufficient_stock(product, requested_qty) do

      config = Product.fetch_warehouse_config(product)
      policy = Warehouse.get_zone_policy(config.storage_zone)

      effective_qty = ceil(requested_qty * @buffer_multiplier)

      if effective_qty < config.min_reserve_quantity do
        {:error, :below_minimum_reserve_quantity}
      else
        window_seconds = policy.reservation_window_hours * 3_600
        expires_at     = DateTime.add(DateTime.utc_now(), window_seconds, :second)

        reservation = %Reservation{
          id:           build_reservation_id(),
          order_id:     order_id,
          product_id:   product_id,
          quantity:     effective_qty,
          storage_zone: config.storage_zone,
          expires_at:   expires_at,
          auto_release: policy.auto_release_enabled,
          status:       :active,
          reserved_at:  DateTime.utc_now()
        }

        with {:ok, saved} <- Repo.insert(reservation),
             :ok          <- ReservationLedger.record(saved) do
          Logger.info(
            "[StockReserver] Reserved #{effective_qty} × #{product_id} for order=#{order_id}"
          )

          {:ok, saved}
        end
      end
    end
  end

  @spec release(String.t()) :: :ok | {:error, atom()}
  def release(reservation_id) do
    with {:ok, reservation} <- fetch_by_id(reservation_id),
         :ok                <- ensure_releasable(reservation) do
      reservation
      |> Reservation.changeset(%{status: :released, released_at: DateTime.utc_now()})
      |> Repo.update()

      Logger.info("[StockReserver] Released reservation=#{reservation_id}")
      :ok
    end
  end

  @spec confirm(String.t()) :: {:ok, Reservation.t()} | {:error, atom()}
  def confirm(reservation_id) do
    with {:ok, reservation} <- fetch_by_id(reservation_id),
         :ok                <- ensure_active(reservation),
         :ok                <- ensure_not_expired(reservation) do
      reservation
      |> Reservation.changeset(%{status: :confirmed, confirmed_at: DateTime.utc_now()})
      |> Repo.update()
    end
  end

  @spec purge_expired() :: {:ok, non_neg_integer()}
  def purge_expired do
    now     = DateTime.utc_now()
    expired = Repo.list_active_reservations_expiring_before(now)

    Enum.each(expired, fn r ->
      r |> Reservation.changeset(%{status: :expired}) |> Repo.update()
    end)

    Logger.info("[StockReserver] Purged #{length(expired)} expired reservation(s)")
    {:ok, length(expired)}
  end


  defp ensure_product_active(%{status: :active}), do: :ok
  defp ensure_product_active(_), do: {:error, :product_not_active}

  defp ensure_sufficient_stock(%{available_stock: stock}, qty) when stock >= qty, do: :ok
  defp ensure_sufficient_stock(_, _), do: {:error, :insufficient_stock}

  defp ensure_releasable(%{status: status}) when status in [:active, :confirmed], do: :ok
  defp ensure_releasable(_), do: {:error, :reservation_not_releasable}

  defp ensure_active(%{status: :active}), do: :ok
  defp ensure_active(_), do: {:error, :reservation_not_active}

  defp ensure_not_expired(%{expires_at: exp}) do
    if DateTime.compare(exp, DateTime.utc_now()) == :gt,
      do: :ok,
      else: {:error, :reservation_expired}
  end

  defp fetch_by_id(id) do
    case Repo.get(Reservation, id) do
      nil -> {:error, :not_found}
      r   -> {:ok, r}
    end
  end

  defp build_reservation_id do
    suffix = :crypto.strong_rand_bytes(8) |> Base.encode16()
    "#{@reservation_id_prefix}-#{suffix}"
  end
end
```
