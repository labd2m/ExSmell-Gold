```elixir
defmodule Orders.FulfillmentPipeline do
  @moduledoc """
  Processes an order through the fulfillment lifecycle: validation, payment capture,
  warehouse allocation, and shipment creation. Each stage is isolated and composable.
  """

  alias Orders.{Order, PaymentGateway, WarehouseAllocator, ShipmentCreator, FulfillmentRecord}

  @type fulfillment_result ::
          {:ok, FulfillmentRecord.t()} | {:error, :validation_failed | :payment_failed | :allocation_failed | :shipment_failed, String.t()}

  @spec fulfill(Order.t()) :: fulfillment_result()
  def fulfill(%Order{} = order) do
    with :ok <- validate_order(order),
         {:ok, payment_ref} <- capture_payment(order),
         {:ok, allocation} <- allocate_inventory(order),
         {:ok, shipment} <- create_shipment(order, allocation) do
      record = FulfillmentRecord.new(order, payment_ref, allocation, shipment)
      {:ok, record}
    end
  end

  @spec validate_order(Order.t()) :: :ok | {:error, :validation_failed, String.t()}
  defp validate_order(%Order{line_items: []}),
    do: {:error, :validation_failed, "Order has no line items"}

  defp validate_order(%Order{shipping_address: nil}),
    do: {:error, :validation_failed, "Order has no shipping address"}

  defp validate_order(%Order{total_cents: total}) when total <= 0,
    do: {:error, :validation_failed, "Order total must be positive"}

  defp validate_order(_order), do: :ok

  @spec capture_payment(Order.t()) :: {:ok, String.t()} | {:error, :payment_failed, String.t()}
  defp capture_payment(order) do
    case PaymentGateway.capture(order.payment_method_id, order.total_cents, order.currency) do
      {:ok, ref} -> {:ok, ref}
      {:error, reason} -> {:error, :payment_failed, reason}
    end
  end

  @spec allocate_inventory(Order.t()) ::
          {:ok, WarehouseAllocator.allocation()} | {:error, :allocation_failed, String.t()}
  defp allocate_inventory(order) do
    case WarehouseAllocator.allocate(order.id, order.line_items) do
      {:ok, allocation} -> {:ok, allocation}
      {:error, reason} -> {:error, :allocation_failed, reason}
    end
  end

  @spec create_shipment(Order.t(), WarehouseAllocator.allocation()) ::
          {:ok, ShipmentCreator.shipment()} | {:error, :shipment_failed, String.t()}
  defp create_shipment(order, allocation) do
    case ShipmentCreator.create(order.id, allocation, order.shipping_address) do
      {:ok, shipment} -> {:ok, shipment}
      {:error, reason} -> {:error, :shipment_failed, reason}
    end
  end
end

defmodule Orders.FulfillmentSupervisor do
  @moduledoc """
  Supervises concurrent order fulfillment tasks dispatched via `Task.Supervisor`.
  Provides async fulfillment with result callbacks and failure isolation.
  """

  use Supervisor

  alias Orders.FulfillmentPipeline

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(_opts) do
    children = [{Task.Supervisor, name: Orders.FulfillmentTaskSupervisor}]
    Supervisor.init(children, strategy: :one_for_one)
  end

  @spec fulfill_async(Orders.Order.t(), (Orders.FulfillmentPipeline.fulfillment_result() -> any())) :: {:ok, Task.t()}
  def fulfill_async(%Orders.Order{} = order, callback) when is_function(callback, 1) do
    task = Task.Supervisor.async_nolink(Orders.FulfillmentTaskSupervisor, fn ->
      result = FulfillmentPipeline.fulfill(order)
      callback.(result)
      result
    end)

    {:ok, task}
  end
end
```
