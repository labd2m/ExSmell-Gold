```elixir
defmodule Fulfillment.AllocationService do
  @moduledoc """
  Coordinates multi-warehouse inventory allocation for order line items.

  Allocation follows a saga pattern: each warehouse claim is recorded before
  the next is attempted. On partial failure, all prior claims are compensated
  (released) before returning an error.
  """

  alias Fulfillment.AllocationService.{WarehouseSelector, ClaimLedger, AllocationPlan}
  alias Fulfillment.Warehouses

  @type line_item :: %{sku: String.t(), quantity: pos_integer()}
  @type allocation_result :: %{sku: String.t(), warehouse_id: String.t(), quantity: pos_integer()}

  @doc """
  Allocates all line items for an order across available warehouses.

  Returns `{:ok, [allocation_result]}` if all items are fully allocated,
  or `{:error, reason}` after compensating any partial claims.
  """
  @spec allocate(String.t(), [line_item()]) ::
          {:ok, [allocation_result()]} | {:error, String.t()}
  def allocate(order_id, line_items)
      when is_binary(order_id) and is_list(line_items) and line_items != [] do
    with {:ok, plan} <- build_allocation_plan(line_items),
         {:ok, allocations} <- execute_plan(order_id, plan) do
      {:ok, allocations}
    end
  end

  def allocate(_, _), do: {:error, "order_id and at least one line item are required"}

  @doc """
  Releases all warehouse claims for a previously allocated order.
  """
  @spec release(String.t()) :: :ok | {:error, String.t()}
  def release(order_id) when is_binary(order_id) do
    case ClaimLedger.fetch_claims(order_id) do
      {:ok, claims} -> compensate_all(claims)
      {:error, :not_found} -> {:error, "no allocations found for order #{order_id}"}
    end
  end

  # --- private helpers ---

  defp build_allocation_plan(line_items) do
    Enum.reduce_while(line_items, {:ok, []}, fn item, {:ok, acc} ->
      case WarehouseSelector.select(item.sku, item.quantity) do
        {:ok, warehouse_id} ->
          {:cont, {:ok, [{item.sku, item.quantity, warehouse_id} | acc]}}

        {:error, reason} ->
          {:halt, {:error, "cannot allocate #{item.sku}: #{reason}"}}
      end
    end)
    |> case do
      {:ok, plan_items} -> {:ok, AllocationPlan.new(Enum.reverse(plan_items))}
      error -> error
    end
  end

  defp execute_plan(order_id, %AllocationPlan{items: items}) do
    Enum.reduce_while(items, {:ok, []}, fn {sku, qty, warehouse_id}, {:ok, committed} ->
      case Warehouses.claim(warehouse_id, sku, qty, order_id) do
        {:ok, claim} ->
          ClaimLedger.record(order_id, claim)
          allocation = %{sku: sku, warehouse_id: warehouse_id, quantity: qty}
          {:cont, {:ok, [allocation | committed]}}

        {:error, reason} ->
          compensate_all(committed)
          {:halt, {:error, "claim failed for #{sku} at #{warehouse_id}: #{reason}"}}
      end
    end)
    |> case do
      {:ok, allocations} -> {:ok, Enum.reverse(allocations)}
      error -> error
    end
  end

  defp compensate_all(claims) do
    Enum.each(claims, fn claim ->
      case Warehouses.release_claim(claim) do
        :ok -> :ok
        {:error, reason} ->
          require Logger
          Logger.error("compensation failed for claim #{inspect(claim)}: #{reason}")
      end
    end)

    :ok
  end
end

defmodule Fulfillment.AllocationService.AllocationPlan do
  @moduledoc false

  @enforce_keys [:items]
  defstruct [:items]

  @type item :: {String.t(), pos_integer(), String.t()}
  @type t :: %__MODULE__{items: [item()]}

  @spec new([item()]) :: t()
  def new(items) when is_list(items), do: %__MODULE__{items: items}
end

defmodule Fulfillment.AllocationService.ClaimLedger do
  @moduledoc "Tracks warehouse claims per order for compensation purposes."

  use Agent

  @doc false
  def start_link(_opts), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  @spec record(String.t(), map()) :: :ok
  def record(order_id, claim) when is_binary(order_id) do
    Agent.update(__MODULE__, fn ledger ->
      Map.update(ledger, order_id, [claim], &[claim | &1])
    end)
  end

  @spec fetch_claims(String.t()) :: {:ok, [map()]} | {:error, :not_found}
  def fetch_claims(order_id) when is_binary(order_id) do
    Agent.get(__MODULE__, fn ledger ->
      case Map.fetch(ledger, order_id) do
        {:ok, claims} -> {:ok, claims}
        :error -> {:error, :not_found}
      end
    end)
  end
end
```
