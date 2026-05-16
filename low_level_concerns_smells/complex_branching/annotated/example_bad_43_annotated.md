# Annotated Example — Code Smell Validation

## Metadata

- **Smell name:** Complex branching
- **Expected smell location:** `parse_reservation_response/2` function
- **Affected function(s):** `parse_reservation_response/2`
- **Short explanation:** The function handles every possible outcome from a single inventory reservation endpoint — confirmed, partially filled, back-ordered, substituted, rejected for multiple reasons, and various server faults — all in one `case` expression with nested sub-cases. Concentrating all of these branches in one place inflates cyclomatic complexity, makes individual branches hard to test in isolation, and creates a single fragile point: a bad pattern match in any arm crashes the entire function.

---

```elixir
defmodule Inventory.WarehouseClient do
  @moduledoc """
  HTTP client for the warehouse management system (WMS) API.
  Handles stock reservations, releases, adjustments, and transfer orders.
  """

  require Logger

  @base_url "https://wms.internal.company.com/api/v2"

  def reserve_stock(order_id, line_items, warehouse_id, opts \\ []) do
    priority = Keyword.get(opts, :priority, "standard")
    hold_minutes = Keyword.get(opts, :hold_minutes, 30)
    allow_substitutes = Keyword.get(opts, :allow_substitutes, false)

    payload = %{
      order_id: order_id,
      warehouse_id: warehouse_id,
      priority: priority,
      hold_minutes: hold_minutes,
      allow_substitutes: allow_substitutes,
      line_items:
        Enum.map(line_items, fn item ->
          %{sku: item.sku, qty: item.quantity, unit: Map.get(item, :unit, "ea")}
        end)
    }

    case http_post("#{@base_url}/reservations", payload, auth_headers()) do
      {:ok, raw} ->
        parse_reservation_response(raw, order_id)

      {:error, :timeout} ->
        {:error, :wms_timeout}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  def release_reservation(reservation_id) do
    case http_delete("#{@base_url}/reservations/#{reservation_id}", auth_headers()) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: 404}} -> {:error, :reservation_not_found}
      {:ok, %{status: 409}} -> {:error, :reservation_already_fulfilled}
      {:ok, %{status: status}} -> {:error, {:unexpected_status, status}}
      {:error, reason} -> {:error, {:transport, reason}}
    end
  end

  def adjust_stock(sku, warehouse_id, delta_qty, reason) do
    payload = %{sku: sku, warehouse_id: warehouse_id, delta_qty: delta_qty, reason: reason}

    case http_post("#{@base_url}/adjustments", payload, auth_headers()) do
      {:ok, %{status: 200, body: %{"adjustment_id" => aid}}} ->
        {:ok, %{adjustment_id: aid}}

      {:ok, %{status: 400, body: %{"error" => msg}}} ->
        {:error, {:validation, msg}}

      {:ok, %{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  # VALIDATION: SMELL START - Complex branching
  # VALIDATION: This is a smell because `parse_reservation_response/2` is solely
  # responsible for interpreting every HTTP status and response body variant from
  # the WMS reservation endpoint. The 200 path branches across four distinct
  # body shapes (confirmed, partial, backorder, substituted) each with different
  # required fields. The 400 path branches across out_of_stock, sku_not_found,
  # warehouse_closed, max_hold_exceeded, and generic errors. Additional arms
  # cover warehouse locking (423), capacity limits (507), and multiple server
  # error shapes. This high branch count makes the function very long, hard to
  # reason about, and dangerous: a MatchError in any one arm (e.g., a missing
  # "substitutions" key) prevents all other response types from being handled.
  defp parse_reservation_response(response, order_id) do
    case response do
      %{status: 200, body: body} ->
        case body do
          %{
            "status" => "confirmed",
            "reservation_id" => rid,
            "expires_at" => exp,
            "reserved_items" => items
          } ->
            {:ok,
             %{
               reservation_id: rid,
               status: :confirmed,
               expires_at: exp,
               reserved_items: items,
               substitutions: [],
               backorder_items: []
             }}

          %{
            "status" => "partial",
            "reservation_id" => rid,
            "reserved_items" => items,
            "unfulfilled_items" => unfulfilled
          } ->
            Logger.warning("Partial reservation for order=#{order_id} unfulfilled=#{inspect(unfulfilled)}")

            {:ok,
             %{
               reservation_id: rid,
               status: :partial,
               expires_at: nil,
               reserved_items: items,
               substitutions: [],
               backorder_items: unfulfilled
             }}

          %{
            "status" => "backordered",
            "reservation_id" => rid,
            "expected_date" => date,
            "backorder_items" => items
          } ->
            {:ok,
             %{
               reservation_id: rid,
               status: :backordered,
               expires_at: nil,
               reserved_items: [],
               substitutions: [],
               backorder_items: items,
               expected_date: date
             }}

          %{
            "status" => "substituted",
            "reservation_id" => rid,
            "substitutions" => subs,
            "expires_at" => exp
          } ->
            Logger.info("Substitution applied for order=#{order_id} subs=#{inspect(subs)}")

            {:ok,
             %{
               reservation_id: rid,
               status: :substituted,
               expires_at: exp,
               reserved_items: [],
               substitutions: subs,
               backorder_items: []
             }}

          %{"status" => unknown} ->
            {:error, {:unknown_reservation_status, unknown}}

          _ ->
            {:error, :malformed_reservation_body}
        end

      %{status: 400, body: body} ->
        case body do
          %{"error" => "out_of_stock", "skus" => skus} ->
            {:error, {:out_of_stock, skus}}

          %{"error" => "sku_not_found", "sku" => sku} ->
            {:error, {:sku_not_found, sku}}

          %{"error" => "warehouse_closed", "reopens_at" => ts} ->
            {:error, {:warehouse_closed, ts}}

          %{"error" => "invalid_warehouse"} ->
            {:error, :invalid_warehouse}

          %{"error" => "max_hold_exceeded", "max_minutes" => max} ->
            {:error, {:max_hold_exceeded, max}}

          %{"error" => msg} ->
            {:error, {:bad_request, msg}}

          _ ->
            {:error, :bad_request}
        end

      %{status: 401} ->
        Logger.error("WMS unauthorized for order=#{order_id}")
        {:error, :unauthorized}

      %{status: 403, body: %{"error" => "insufficient_permissions", "required" => perm}} ->
        {:error, {:insufficient_permissions, perm}}

      %{status: 403} ->
        {:error, :forbidden}

      %{status: 404, body: %{"error" => "warehouse_not_found"}} ->
        {:error, :warehouse_not_found}

      %{status: 404} ->
        {:error, :not_found}

      %{status: 409, body: %{"error" => "duplicate_reservation", "existing_id" => eid}} ->
        {:error, {:duplicate_reservation, eid}}

      %{status: 409} ->
        {:error, :conflict}

      %{status: 423, body: %{"error" => "warehouse_locked", "unlock_at" => ts}} ->
        {:error, {:warehouse_locked, ts}}

      %{status: 429, body: %{"retry_after" => sec}} ->
        {:error, {:rate_limited, sec}}

      %{status: 429} ->
        {:error, :rate_limited}

      %{status: 500, body: %{"incident_id" => iid}} ->
        Logger.error("WMS 500 incident_id=#{iid} order=#{order_id}")
        {:error, {:server_error, iid}}

      %{status: 500} ->
        {:error, :server_error}

      %{status: 507, body: %{"error" => "storage_capacity_exceeded"}} ->
        {:error, :storage_capacity_exceeded}

      %{status: status, body: body} ->
        Logger.warning("Unhandled WMS status=#{status} order=#{order_id} body=#{inspect(body)}")
        {:error, {:unexpected_response, status}}
    end
  end
  # VALIDATION: SMELL END

  defp auth_headers do
    token = System.get_env("WMS_API_TOKEN", "")
    [{"Authorization", "Bearer #{token}"}, {"Content-Type", "application/json"}]
  end

  defp http_post(_url, _payload, _headers), do: {:error, :not_implemented}
  defp http_delete(_url, _headers), do: {:error, :not_implemented}
end
```
