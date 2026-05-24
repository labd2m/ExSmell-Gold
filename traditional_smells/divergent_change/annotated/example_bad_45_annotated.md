# Annotated Example — Code Smell Validation

## Metadata

- **Smell name:** Divergent Change
- **Expected smell location:** The entire `OrderProcessor` module
- **Affected function(s):** `place_order/2`, `cancel_order/2`, `confirm_shipment/2`, `calculate_shipping_rate/2`, `estimate_delivery_date/2`, `award_loyalty_points/2`, `redeem_loyalty_points/2`
- **Short explanation:** The `OrderProcessor` module mixes three unrelated concerns — order lifecycle management, shipping rate/date estimation, and a loyalty points programme. Changes to carrier integrations, changes to the rewards programme rules, and changes to order state machine logic are all entirely independent reasons to touch this module.

---

```elixir
defmodule MyApp.OrderProcessor do
  @moduledoc """
  Manages orders from placement through fulfilment, computes shipping costs,
  and handles customer loyalty-point transactions.
  """

  alias MyApp.Repo
  alias MyApp.Orders.{Order, OrderItem}
  alias MyApp.Customers.{Customer, LoyaltyAccount}
  import Ecto.Changeset

  # VALIDATION: SMELL START - Divergent Change
  # VALIDATION: This is a smell because the module owns three unrelated responsibility
  # VALIDATION: clusters. Order lifecycle (place/cancel/confirm), shipping estimation
  # VALIDATION: (rates/dates), and loyalty points (award/redeem) each evolve for
  # VALIDATION: completely independent reasons, yet all modifications land in this one
  # VALIDATION: module — a textbook Divergent Change situation.

  # ── Reason to modify (1): Order lifecycle & state machine ──────────────────

  @valid_transitions %{
    pending: [:confirmed, :cancelled],
    confirmed: [:shipped, :cancelled],
    shipped: [:delivered],
    delivered: [],
    cancelled: []
  }

  def place_order(customer_id, line_items) when is_list(line_items) do
    Repo.transaction(fn ->
      customer = Repo.get!(Customer, customer_id)

      order =
        %Order{}
        |> Order.changeset(%{
          customer_id: customer.id,
          status: :pending,
          placed_at: DateTime.utc_now()
        })
        |> Repo.insert!()

      items =
        Enum.map(line_items, fn %{sku: sku, qty: qty, unit_price: price} ->
          %OrderItem{}
          |> OrderItem.changeset(%{order_id: order.id, sku: sku, quantity: qty, unit_price: price})
          |> Repo.insert!()
        end)

      %{order | items: items}
    end)
  end

  def cancel_order(order_id, reason) do
    with {:ok, order} <- fetch_order(order_id),
         :ok <- validate_transition(order.status, :cancelled) do
      order
      |> Order.changeset(%{status: :cancelled, cancellation_reason: reason})
      |> Repo.update()
    end
  end

  def confirm_shipment(order_id, tracking_number) do
    with {:ok, order} <- fetch_order(order_id),
         :ok <- validate_transition(order.status, :shipped) do
      order
      |> Order.changeset(%{status: :shipped, tracking_number: tracking_number, shipped_at: DateTime.utc_now()})
      |> Repo.update()
    end
  end

  defp fetch_order(order_id) do
    case Repo.get(Order, order_id) do
      nil -> {:error, :not_found}
      order -> {:ok, Repo.preload(order, :items)}
    end
  end

  defp validate_transition(from, to) do
    if to in Map.get(@valid_transitions, from, []) do
      :ok
    else
      {:error, {:invalid_transition, from, to}}
    end
  end

  # ── Reason to modify (2): Shipping rate & delivery estimation ───────────────

  @carrier_rates %{
    standard: %{base: 4.99, per_kg: 0.80, days: 5},
    express: %{base: 9.99, per_kg: 1.20, days: 2},
    overnight: %{base: 19.99, per_kg: 2.00, days: 1}
  }

  def calculate_shipping_rate(weight_kg, service) when is_atom(service) do
    case Map.fetch(@carrier_rates, service) do
      :error ->
        {:error, :unknown_service}

      {:ok, %{base: base, per_kg: rate}} ->
        total = Float.round(base + rate * weight_kg, 2)
        {:ok, total}
    end
  end

  def estimate_delivery_date(service, origin_country, destination_country) do
    base_days =
      case Map.fetch(@carrier_rates, service) do
        :error -> {:error, :unknown_service}
        {:ok, %{days: d}} -> {:ok, d}
      end

    with {:ok, days} <- base_days do
      cross_border_extra = if origin_country != destination_country, do: 3, else: 0
      total_days = days + cross_border_extra
      estimated = Date.add(Date.utc_today(), total_days)
      {:ok, estimated}
    end
  end

  # ── Reason to modify (3): Loyalty points programme ─────────────────────────

  @points_per_dollar 10
  @min_redemption_points 500

  def award_loyalty_points(customer_id, order_total_cents) do
    points = div(order_total_cents, 100) * @points_per_dollar
    account = get_or_create_loyalty_account(customer_id)

    account
    |> LoyaltyAccount.changeset(%{balance: account.balance + points})
    |> Repo.update()
  end

  def redeem_loyalty_points(customer_id, points_to_redeem) do
    account = get_or_create_loyalty_account(customer_id)

    cond do
      points_to_redeem < @min_redemption_points ->
        {:error, :below_minimum_redemption}

      account.balance < points_to_redeem ->
        {:error, :insufficient_points}

      true ->
        account
        |> LoyaltyAccount.changeset(%{balance: account.balance - points_to_redeem})
        |> Repo.update()
    end
  end

  defp get_or_create_loyalty_account(customer_id) do
    case Repo.get_by(LoyaltyAccount, customer_id: customer_id) do
      nil ->
        %LoyaltyAccount{}
        |> LoyaltyAccount.changeset(%{customer_id: customer_id, balance: 0})
        |> Repo.insert!()

      account ->
        account
    end
  end

  # VALIDATION: SMELL END
end
```
