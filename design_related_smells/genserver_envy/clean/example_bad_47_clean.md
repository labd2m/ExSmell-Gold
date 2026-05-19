```elixir
defmodule OrderProcessorTask do
  @moduledoc """
  Manages the lifecycle of a single customer order from cart assembly
  through confirmation. One Task process is spawned per active order.
  """

  require Logger

  @order_timeout_ms :timer.minutes(15)

  @type order_state :: %{
          order_id: String.t(),
          customer_id: String.t(),
          items: list(map()),
          coupons: list(String.t()),
          subtotal: float(),
          discount: float(),
          tax: float(),
          status: :open | :confirmed | :cancelled
        }

  @doc """
  Starts a Task to manage an order. The Task stays alive until the order
  is confirmed, cancelled, or times out.
  """
  def start_for_order(order_id, customer_id) do
    initial = %{
      order_id: order_id,
      customer_id: customer_id,
      items: [],
      coupons: [],
      subtotal: 0.0,
      discount: 0.0,
      tax: 0.0,
      status: :open
    }

    Task.start(fn ->
      Logger.info("[OrderProcessorTask] Starting order #{order_id}")

      processor_loop(initial)
    end)
  end

  defp processor_loop(%{status: status} = order) when status in [:confirmed, :cancelled] do
    Logger.info("[OrderProcessorTask] Order #{order.order_id} closed with status: #{status}")
    :ok
  end

  defp processor_loop(order) do
    receive do
      {:add_item, item, from_pid} ->
        new_subtotal = order.subtotal + item.price * item.qty
        updated = %{order | items: [item | order.items], subtotal: new_subtotal}
        recalculated = recalculate(updated)
        send(from_pid, {:add_item_result, :ok, Map.take(recalculated, [:subtotal, :tax])})
        processor_loop(recalculated)

      {:remove_item, item_id, from_pid} ->
        remaining = Enum.reject(order.items, &(&1.id == item_id))
        new_subtotal = remaining |> Enum.map(&(&1.price * &1.qty)) |> Enum.sum()
        updated = %{order | items: remaining, subtotal: new_subtotal}
        recalculated = recalculate(updated)
        send(from_pid, {:remove_item_result, :ok})
        processor_loop(recalculated)

      {:apply_coupon, code, from_pid} ->
        if code in order.coupons do
          send(from_pid, {:coupon_result, {:error, :already_applied}})
          processor_loop(order)
        else
          discount_pct = resolve_discount(code)
          new_discount = Float.round(order.subtotal * discount_pct, 2)
          updated = %{order | coupons: [code | order.coupons], discount: new_discount}
          recalculated = recalculate(updated)
          send(from_pid, {:coupon_result, {:ok, new_discount}})
          processor_loop(recalculated)
        end

      {:get_summary, from_pid} ->
        send(from_pid, {:summary, order})
        processor_loop(order)

      {:confirm, from_pid} ->
        if Enum.empty?(order.items) do
          send(from_pid, {:confirm_result, {:error, :empty_order}})
          processor_loop(order)
        else
          confirmed = %{order | status: :confirmed}
          Logger.info("[OrderProcessorTask] Order #{order.order_id} confirmed")
          send(from_pid, {:confirm_result, {:ok, confirmed}})
          processor_loop(confirmed)
        end

      {:cancel, reason, from_pid} ->
        Logger.info("[OrderProcessorTask] Order #{order.order_id} cancelled: #{reason}")
        cancelled = %{order | status: :cancelled}
        send(from_pid, {:cancel_result, :ok})
        processor_loop(cancelled)
    after
      @order_timeout_ms ->
        Logger.warning("[OrderProcessorTask] Order #{order.order_id} timed out")
        :timeout
    end
  end

  defp recalculate(order) do
    taxable = max(order.subtotal - order.discount, 0.0)
    %{order | tax: Float.round(taxable * 0.085, 2)}
  end

  defp resolve_discount("SAVE10"), do: 0.10
  defp resolve_discount("SAVE20"), do: 0.20
  defp resolve_discount("WELCOME"), do: 0.15
  defp resolve_discount(_), do: 0.05

  @doc "Sends an add_item command to a running order Task."
  def add_item(task_pid, item) do
    send(task_pid, {:add_item, item, self()})

    receive do
      {:add_item_result, result, totals} -> {result, totals}
    after
      5_000 -> {:error, :timeout}
    end
  end

  @doc "Applies a coupon code via the running order Task."
  def apply_coupon(task_pid, code) do
    send(task_pid, {:apply_coupon, code, self()})

    receive do
      {:coupon_result, result} -> result
    after
      5_000 -> {:error, :timeout}
    end
  end

  @doc "Fetches current order summary from the running Task."
  def get_summary(task_pid) do
    send(task_pid, {:get_summary, self()})

    receive do
      {:summary, order} -> {:ok, order}
    after
      5_000 -> {:error, :timeout}
    end
  end

  @doc "Confirms the order via the running Task."
  def confirm(task_pid) do
    send(task_pid, {:confirm, self()})

    receive do
      {:confirm_result, result} -> result
    after
      5_000 -> {:error, :timeout}
    end
  end

  @doc "Cancels the order via the running Task."
  def cancel(task_pid, reason \\ :user_requested) do
    send(task_pid, {:cancel, reason, self()})

    receive do
      {:cancel_result, result} -> result
    after
      5_000 -> {:error, :timeout}
    end
  end
end
```
