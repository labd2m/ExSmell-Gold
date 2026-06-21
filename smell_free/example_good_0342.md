```elixir
defmodule Platform.Saga do
  @moduledoc """
  A saga orchestrator for multi-service workflows requiring compensation.

  Unlike an Ecto Multi (which only spans one database), a Saga coordinates
  steps that may call external services. Each step declares a compensating
  function that is invoked in reverse order if any subsequent step fails,
  maintaining system consistency across service boundaries.
  """

  @type step_name :: atom()
  @type step_result :: {:ok, term()} | {:error, term()}
  @type forward_fn :: (map() -> step_result())
  @type compensate_fn :: (map() -> :ok)
  @type step :: {step_name(), forward_fn(), compensate_fn()}

  @type saga_result ::
          {:ok, map()}
          | {:error, step_name(), term(), map()}

  @doc """
  Executes `steps` in order, passing the accumulated results to each step.

  If any step returns `{:error, reason}`, all previously completed steps
  are compensated in reverse order. Returns `{:ok, results}` on full success
  or `{:error, failed_step, reason, completed_results}` on failure.
  """
  @spec run([step()]) :: saga_result()
  def run(steps) when is_list(steps) do
    execute_steps(steps, %{}, [])
  end

  defp execute_steps([], results, _completed), do: {:ok, results}

  defp execute_steps([{name, forward, compensate} | rest], results, completed) do
    case forward.(results) do
      {:ok, value} ->
        updated = Map.put(results, name, value)
        execute_steps(rest, updated, [{name, compensate} | completed])

      {:error, reason} ->
        compensate_all(completed, results)
        {:error, name, reason, results}
    end
  end

  defp compensate_all([], _results), do: :ok

  defp compensate_all([{name, compensate_fn} | rest], results) do
    try do
      compensate_fn.(results)
    rescue
      error ->
        require Logger
        Logger.error("[Saga] Compensation failed for step #{name}", error: inspect(error))
    end

    compensate_all(rest, results)
  end
end

defmodule Commerce.OrderFulfillmentSaga do
  @moduledoc """
  Coordinates the multi-service order fulfillment workflow using `Platform.Saga`.

  Steps: reserve inventory → charge payment → create shipment.
  Each step has a compensating action to reverse on downstream failure.
  """

  alias Platform.Saga
  alias Commerce.{Inventory, Payments, Shipments}

  @type order :: map()
  @type fulfillment_result :: {:ok, map()} | {:error, atom(), term(), map()}

  @doc "Runs the full order fulfillment saga for the given order."
  @spec run(order()) :: fulfillment_result()
  def run(%{id: _} = order) do
    Saga.run([
      {:reserve_inventory, &reserve_inventory(order, &1), &release_inventory/1},
      {:charge_payment, &charge_payment(order, &1), &refund_payment/1},
      {:create_shipment, &create_shipment(order, &1), &cancel_shipment/1}
    ])
  end

  defp reserve_inventory(order, _results) do
    Inventory.reserve(order.id, order.items)
  end

  defp release_inventory(%{reserve_inventory: reservation_id}) do
    Inventory.release(reservation_id)
  end

  defp charge_payment(order, _results) do
    Payments.charge(order.payment_method_id, order.total_cents, idempotency_key: "order-#{order.id}")
  end

  defp refund_payment(%{charge_payment: charge_id}) do
    Payments.refund(charge_id)
  end

  defp create_shipment(order, %{reserve_inventory: reservation_id}) do
    Shipments.create(%{order_id: order.id, reservation_id: reservation_id, address: order.shipping_address})
  end

  defp cancel_shipment(%{create_shipment: shipment_id}) do
    Shipments.cancel(shipment_id)
  end
end
```
