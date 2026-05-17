```elixir
# ── file: lib/inventory/stock_manager.ex ────────────────────────────────────


defmodule Inventory.StockManager do
  @moduledoc """
  Manages inventory reservations, releases, and committed stock adjustments.
  Defined in `lib/inventory/stock_manager.ex`.
  """

  alias Inventory.{ReservationStore, StockLedger, Product}

  @reservation_ttl_seconds 900

  @type reservation_id :: String.t()
  @type sku :: String.t()
  @type quantity :: non_neg_integer()

  @doc """
  Reserve `qty` units of `sku` for an order.
  Returns `{:ok, reservation_id}` or `{:error, reason}`.
  """
  @spec reserve(sku(), quantity(), String.t()) ::
          {:ok, reservation_id()} | {:error, String.t()}
  def reserve(sku, qty, order_id) when is_binary(sku) and qty > 0 do
    with {:ok, product} <- Product.fetch(sku),
         :ok <- check_availability(product, qty) do
      reservation = %{
        id: generate_id(),
        sku: sku,
        quantity: qty,
        order_id: order_id,
        expires_at: System.system_time(:second) + @reservation_ttl_seconds,
        status: :pending
      }

      case ReservationStore.save(reservation) do
        {:ok, _} -> {:ok, reservation.id}
        {:error, reason} -> {:error, "Failed to save reservation: #{inspect(reason)}"}
      end
    end
  end

  def reserve(_sku, qty, _order_id) when qty <= 0 do
    {:error, "Quantity must be positive"}
  end

  @doc "Release a pending reservation, making the stock available again."
  @spec release(reservation_id(), String.t()) :: :ok | {:error, String.t()}
  def release(reservation_id, reason \\ "manual_release") do
    case ReservationStore.fetch(reservation_id) do
      {:ok, %{status: :pending} = res} ->
        ReservationStore.update(res.id, %{status: :released, release_reason: reason})

      {:ok, %{status: status}} ->
        {:error, "Cannot release reservation in status: #{status}"}

      :not_found ->
        {:error, "Reservation not found: #{reservation_id}"}
    end
  end

  @doc "Commit a reservation, permanently decrementing stock in the ledger."
  @spec commit(reservation_id(), String.t()) :: :ok | {:error, String.t()}
  def commit(reservation_id, fulfilled_by) do
    with {:ok, %{status: :pending, sku: sku, quantity: qty} = res} <-
           ReservationStore.fetch(reservation_id),
         :ok <- StockLedger.decrement(sku, qty, fulfilled_by) do
      ReservationStore.update(res.id, %{status: :committed})
    else
      {:ok, %{status: s}} -> {:error, "Reservation not pending (status: #{s})"}
      :not_found -> {:error, "Reservation not found: #{reservation_id}"}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Return the real-time available quantity for a SKU."
  @spec available_quantity(sku()) :: {:ok, quantity()} | {:error, String.t()}
  def available_quantity(sku) do
    with {:ok, product} <- Product.fetch(sku),
         {:ok, reserved} <- ReservationStore.total_reserved(sku) do
      available = max(product.stock_level - reserved, 0)
      {:ok, available}
    end
  end

  @doc "Emit a reorder alert if stock falls below the product's reorder threshold."
  @spec reorder_alert(sku()) :: :ok | {:error, String.t()}
  def reorder_alert(sku) do
    with {:ok, product} <- Product.fetch(sku),
         {:ok, available} <- available_quantity(sku) do
      if available <= product.reorder_threshold do
        Inventory.AlertDispatcher.notify(:reorder_needed, %{sku: sku, available: available})
      else
        :ok
      end
    end
  end

  defp check_availability(%{stock_level: sl, reorder_threshold: rt}, qty)
       when sl - qty >= rt,
       do: :ok

  defp check_availability(%{stock_level: sl}, qty) when sl >= qty, do: :ok
  defp check_availability(_, _), do: {:error, "Insufficient stock"}

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end


# ── file: lib/inventory/stock_manager_audit.ex ─────────────────────────────────────────────────────


defmodule Inventory.StockManager do
  @moduledoc """
  Audit trail utilities for stock management operations.
  """

  alias Inventory.AuditLog

  @doc "Record a stock reservation event in the audit trail."
  @spec log_reservation(map()) :: :ok
  def log_reservation(%{id: id, sku: sku, quantity: qty, order_id: order_id}) do
    AuditLog.append(%{
      event: :stock_reserved,
      reference_id: id,
      details: %{sku: sku, quantity: qty, order_id: order_id},
      occurred_at: DateTime.utc_now()
    })
  end

  @doc "Record a stock release event in the audit trail."
  @spec log_release(String.t(), String.t()) :: :ok
  def log_release(reservation_id, reason) do
    AuditLog.append(%{
      event: :stock_released,
      reference_id: reservation_id,
      details: %{reason: reason},
      occurred_at: DateTime.utc_now()
    })
  end

  @doc "Record a stock commitment event in the audit trail."
  @spec log_commit(String.t(), String.t()) :: :ok
  def log_commit(reservation_id, fulfilled_by) do
    AuditLog.append(%{
      event: :stock_committed,
      reference_id: reservation_id,
      details: %{fulfilled_by: fulfilled_by},
      occurred_at: DateTime.utc_now()
    })
  end

  @doc "Return all audit entries for a given SKU in descending time order."
  @spec history(String.t()) :: [map()]
  def history(sku) do
    AuditLog.query(sku: sku)
    |> Enum.sort_by(& &1.occurred_at, {:desc, DateTime})
  end
end

```
