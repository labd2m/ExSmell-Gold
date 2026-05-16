```elixir
defmodule MyApp.Warehouse.PickingCoordinator do
  @moduledoc """
  Coordinates order picking in warehouse fulfillment centers. Groups open order lines
  into picking batches, assigns them to picker zones, and tracks completion status.
  """

  require Logger

  alias MyApp.Warehouse.{
    OrderLineQueue,
    PickingBatch,
    PickerAssignment,
    ZoneMap,
    FulfillmentTracker
  }

  @default_batch_size 20
  @max_batch_size 100
  @supported_strategies [:zone_based, :order_based, :product_based]

  @type batch_opts :: [
          batch_size: pos_integer(),
          strategy: atom(),
          zone_id: String.t() | nil,
          priority_only: boolean()
        ]

  @spec create_batches(String.t(), [String.t()], batch_opts()) ::
          {:ok, [PickingBatch.t()]} | {:error, atom()}
  def create_batches(warehouse_id, order_ids, opts \\ []) do
    strategy = Keyword.get(opts, :strategy, :order_based)
    zone_id = Keyword.get(opts, :zone_id)
    priority_only = Keyword.get(opts, :priority_only, false)
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)

    with :ok <- validate_strategy(strategy),
         {:ok, lines} <- OrderLineQueue.fetch_open(warehouse_id, order_ids, priority_only),
         {:ok, sorted_lines} <- sort_lines(lines, strategy, zone_id) do

      batches =
        sorted_lines
        |> Enum.chunk_every(batch_size)
        |> Enum.with_index(1)
        |> Enum.map(fn {chunk, idx} ->
          build_batch(warehouse_id, chunk, idx, strategy)
        end)

      saved_batches =
        Enum.map(batches, fn batch ->
          case PickingBatch.create(batch) do
            {:ok, saved} -> saved
            {:error, _} -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      Logger.info(
        "Picking batches created: warehouse=#{warehouse_id} " <>
          "batches=#{length(saved_batches)} lines=#{length(lines)} strategy=#{strategy}"
      )

      {:ok, saved_batches}
    end
  end

  @spec assign_batch(String.t(), String.t()) :: {:ok, PickerAssignment.t()} | {:error, atom()}
  def assign_batch(batch_id, picker_id) do
    with {:ok, batch} <- PickingBatch.fetch(batch_id),
         :ok <- check_batch_unassigned(batch),
         {:ok, picker} <- fetch_available_picker(picker_id) do
      PickerAssignment.create(%{
        batch_id: batch_id,
        picker_id: picker_id,
        assigned_at: DateTime.utc_now(),
        expected_completion: compute_expected_completion(batch)
      })
    end
  end

  @spec complete_line(String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, atom()}
  def complete_line(batch_id, line_id, completion_data) do
    with {:ok, batch} <- PickingBatch.fetch(batch_id),
         :ok <- check_line_belongs_to_batch(batch, line_id) do
      FulfillmentTracker.record_line_completion(line_id, completion_data)
      check_batch_completion(batch_id)
    end
  end

  @spec open_batches(String.t()) :: {:ok, [PickingBatch.t()]}
  def open_batches(warehouse_id) do
    PickingBatch.list_open(warehouse_id)
  end

  # Private helpers

  defp validate_strategy(strategy) when strategy in @supported_strategies, do: :ok
  defp validate_strategy(_), do: {:error, :invalid_strategy}

  defp sort_lines(lines, :zone_based, zone_id) do
    sorted =
      lines
      |> Enum.filter(fn line -> zone_id == nil or line.zone_id == zone_id end)
      |> Enum.sort_by(& &1.zone_id)

    {:ok, sorted}
  end

  defp sort_lines(lines, :order_based, _zone_id) do
    {:ok, Enum.sort_by(lines, &{&1.priority, &1.order_id})}
  end

  defp sort_lines(lines, :product_based, _zone_id) do
    {:ok, Enum.sort_by(lines, &{&1.aisle, &1.bin_number})}
  end

  defp build_batch(warehouse_id, lines, index, strategy) do
    %{
      id: Ecto.UUID.generate(),
      warehouse_id: warehouse_id,
      index: index,
      strategy: strategy,
      line_ids: Enum.map(lines, & &1.id),
      line_count: length(lines),
      status: :pending,
      created_at: DateTime.utc_now()
    }
  end

  defp check_batch_unassigned(%{status: :pending}), do: :ok
  defp check_batch_unassigned(_), do: {:error, :batch_already_assigned}

  defp fetch_available_picker(picker_id) do
    {:ok, %{id: picker_id, status: :available}}
  end

  defp compute_expected_completion(batch) do
    minutes_per_line = 2
    DateTime.add(DateTime.utc_now(), batch.line_count * minutes_per_line * 60, :second)
  end

  defp check_line_belongs_to_batch(batch, line_id) do
    if line_id in batch.line_ids, do: :ok, else: {:error, :line_not_in_batch}
  end

  defp check_batch_completion(batch_id) do
    case PickingBatch.all_lines_complete?(batch_id) do
      true -> PickingBatch.mark_complete(batch_id)
      false -> {:ok, :in_progress}
    end
  end
end
```
