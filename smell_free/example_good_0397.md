```elixir
defmodule Commerce.OrderSaga do
  @moduledoc """
  Coordinates the multi-step order fulfilment saga using explicit compensating
  transactions. Each step is a `{forward, compensate}` pair. When any forward
  step fails, all previously completed steps are rolled back in reverse order.
  This approach provides eventual consistency across services (inventory,
  payment, shipping) without requiring distributed transactions.

  The saga state is an accumulator map that forward functions can enrich
  so later steps can reference outputs from earlier ones.
  """

  require Logger

  @type step_name :: atom()
  @type saga_context :: map()
  @type step :: %{
          name: step_name(),
          run: (saga_context() -> {:ok, saga_context()} | {:error, term()}),
          compensate: (saga_context() -> :ok)
        }

  @type saga_result :: {:ok, saga_context()} | {:error, step_name(), term(), saga_context()}

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Executes `steps` in order, passing the accumulated context through each.
  On the first failure, all completed steps are compensated in reverse order.
  Returns `{:ok, final_context}` or `{:error, failed_step, reason, context}`.
  """
  @spec run([step()], saga_context()) :: saga_result()
  def run(steps, initial_context \\ %{}) when is_list(steps) and is_map(initial_context) do
    execute(steps, [], initial_context)
  end

  # ---------------------------------------------------------------------------
  # Order fulfilment steps
  # ---------------------------------------------------------------------------

  @doc """
  Returns the ordered list of steps for the order fulfilment saga.
  Steps are declared here to keep the business logic sequence explicit and
  auditable without scattering saga concerns across multiple modules.
  """
  @spec fulfilment_steps(map()) :: [step()]
  def fulfilment_steps(order_attrs) do
    [
      validate_order_step(order_attrs),
      reserve_inventory_step(),
      charge_payment_step(),
      create_order_record_step(),
      request_shipment_step()
    ]
  end

  # ---------------------------------------------------------------------------
  # Step builders
  # ---------------------------------------------------------------------------

  @spec validate_order_step(map()) :: step()
  defp validate_order_step(order_attrs) do
    %{
      name: :validate_order,
      run: fn ctx ->
        case Commerce.Orders.validate(order_attrs) do
          {:ok, validated} -> {:ok, Map.put(ctx, :validated_attrs, validated)}
          {:error, reason} -> {:error, reason}
        end
      end,
      compensate: fn _ctx -> :ok end
    }
  end

  @spec reserve_inventory_step() :: step()
  defp reserve_inventory_step do
    %{
      name: :reserve_inventory,
      run: fn ctx ->
        case Warehouse.Inventory.reserve(ctx.validated_attrs.items) do
          {:ok, reservation} -> {:ok, Map.put(ctx, :reservation_id, reservation.id)}
          {:error, reason}   -> {:error, reason}
        end
      end,
      compensate: fn ctx ->
        with reservation_id when not is_nil(reservation_id) <- Map.get(ctx, :reservation_id) do
          Warehouse.Inventory.cancel_reservation(reservation_id)
        end
        :ok
      end
    }
  end

  @spec charge_payment_step() :: step()
  defp charge_payment_step do
    %{
      name: :charge_payment,
      run: fn ctx ->
        charge_attrs = %{
          amount_cents: ctx.validated_attrs.total_cents,
          currency:     ctx.validated_attrs.currency,
          customer_id:  ctx.validated_attrs.customer_id
        }

        case Billing.Charges.create(charge_attrs) do
          {:ok, charge}    -> {:ok, Map.put(ctx, :charge_id, charge.id)}
          {:error, reason} -> {:error, reason}
        end
      end,
      compensate: fn ctx ->
        with charge_id when not is_nil(charge_id) <- Map.get(ctx, :charge_id) do
          Billing.Charges.refund(%{
            charge_id:    charge_id,
            amount_cents: ctx.validated_attrs.total_cents,
            reason:       :requested_by_customer
          })
        end
        :ok
      end
    }
  end

  @spec create_order_record_step() :: step()
  defp create_order_record_step do
    %{
      name: :create_order_record,
      run: fn ctx ->
        attrs = Map.merge(ctx.validated_attrs, %{
          charge_id:      ctx.charge_id,
          reservation_id: ctx.reservation_id
        })

        case Commerce.Orders.insert(attrs) do
          {:ok, order}     -> {:ok, Map.put(ctx, :order_id, order.id)}
          {:error, reason} -> {:error, reason}
        end
      end,
      compensate: fn ctx ->
        with order_id when not is_nil(order_id) <- Map.get(ctx, :order_id) do
          Commerce.Orders.cancel(order_id, "saga_rollback")
        end
        :ok
      end
    }
  end

  @spec request_shipment_step() :: step()
  defp request_shipment_step do
    %{
      name: :request_shipment,
      run: fn ctx ->
        case Shipping.create_shipment(ctx.order_id, ctx.validated_attrs.shipping_address) do
          {:ok, shipment}  -> {:ok, Map.put(ctx, :shipment_id, shipment.id)}
          {:error, reason} -> {:error, reason}
        end
      end,
      compensate: fn ctx ->
        with shipment_id when not is_nil(shipment_id) <- Map.get(ctx, :shipment_id) do
          Shipping.cancel_shipment(shipment_id)
        end
        :ok
      end
    }
  end

  # ---------------------------------------------------------------------------
  # Private execution engine
  # ---------------------------------------------------------------------------

  defp execute([], _completed, ctx), do: {:ok, ctx}

  defp execute([step | remaining], completed, ctx) do
    case step.run.(ctx) do
      {:ok, updated_ctx} ->
        execute(remaining, [step | completed], updated_ctx)

      {:error, reason} ->
        Logger.warning("Saga step failed, compensating",
          step:   step.name,
          reason: inspect(reason)
        )
        compensate(completed, ctx)
        {:error, step.name, reason, ctx}
    end
  end

  defp compensate([], _ctx), do: :ok

  defp compensate([step | rest], ctx) do
    try do
      step.compensate.(ctx)
    rescue
      e ->
        Logger.error("Compensation failed for step",
          step:   step.name,
          reason: Exception.message(e)
        )
    end

    compensate(rest, ctx)
  end
end
```
