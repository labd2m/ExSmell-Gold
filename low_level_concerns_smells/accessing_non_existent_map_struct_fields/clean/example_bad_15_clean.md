```elixir
defmodule Warehouse.PickingPlanner do
  @moduledoc """
  Plans and sequences picking tasks for warehouse fulfilment orders.
  Assigns bin locations, estimates pick times, and groups tasks by aisle
  to minimise travel distance.
  """

  require Logger

  @default_priority      :normal
  @pick_time_per_item_s  45
  @zones                 ~w(domestic express international)

  @type pick_task :: %{
          line_ref: String.t(),
          sku: String.t(),
          quantity: integer(),
          bin: String.t(),
          aisle: String.t(),
          estimated_seconds: integer()
        }

  @type pick_plan :: %{
          order_id: String.t(),
          priority: atom(),
          shipping_zone: String.t(),
          tasks: list(pick_task()),
          total_estimated_seconds: integer(),
          created_at: DateTime.t()
        }

  @spec plan_pick(map(), list(map())) :: {:ok, pick_plan()} | {:error, String.t()}
  def plan_pick(order, bin_catalog) do
    items         = order[:items]
    priority      = order[:priority]
    shipping_zone = order[:shipping_zone]

    with :ok <- validate_zone(shipping_zone),
         {:ok, tasks} <- build_tasks(items, bin_catalog) do
      sorted_tasks = sort_by_aisle(tasks)
      total_s      = Enum.sum(Enum.map(sorted_tasks, & &1.estimated_seconds))

      plan = %{
        order_id: order.id,
        priority: priority || @default_priority,
        shipping_zone: shipping_zone,
        tasks: sorted_tasks,
        total_estimated_seconds: total_s,
        created_at: DateTime.utc_now()
      }

      Logger.info("Pick plan created",
        order_id: order.id,
        task_count: length(sorted_tasks),
        priority: plan.priority,
        estimated_minutes: Float.round(total_s / 60, 1)
      )

      {:ok, plan}
    end
  end

  @spec build_tasks(list(map()) | nil, list(map())) ::
          {:ok, list(pick_task())} | {:error, String.t()}
  defp build_tasks(nil, _catalog), do: {:error, "Order items list is missing"}

  defp build_tasks(items, bin_catalog) do
    tasks =
      Enum.map(items, fn item ->
        bin = find_bin(item.sku, bin_catalog)

        %{
          line_ref: item.line_ref,
          sku: item.sku,
          quantity: item.quantity,
          bin: bin.code,
          aisle: bin.aisle,
          estimated_seconds: item.quantity * @pick_time_per_item_s
        }
      end)

    {:ok, tasks}
  rescue
    e -> {:error, "Failed to build tasks: #{Exception.message(e)}"}
  end

  @spec find_bin(String.t(), list(map())) :: map()
  defp find_bin(sku, catalog) do
    Enum.find(catalog, %{code: "UNKNOWN", aisle: "ZZ"}, fn b -> b.sku == sku end)
  end

  @spec sort_by_aisle(list(pick_task())) :: list(pick_task())
  defp sort_by_aisle(tasks) do
    Enum.sort_by(tasks, fn t -> {t.aisle, t.bin} end)
  end

  @spec validate_zone(String.t() | nil) :: :ok | {:error, String.t()}
  defp validate_zone(nil), do: {:error, "Shipping zone is required"}

  defp validate_zone(zone) do
    if zone in @zones do
      :ok
    else
      {:error, "Unknown shipping zone: #{zone}. Valid zones: #{Enum.join(@zones, ", ")}"}
    end
  end
end
```
