```elixir
defmodule Workflow.Step do
  @moduledoc """
  Defines the behaviour all workflow step modules must implement.
  Each step receives the shared workflow context and returns an updated version.
  """

  @callback execute(context :: map()) :: {:ok, map()} | {:error, term()}
  @callback name() :: atom()
end

defmodule Workflow.Runner do
  alias Workflow.Step

  @moduledoc """
  Executes a sequential list of workflow steps, threading context through each.
  Halts immediately on the first failure and reports which step caused it.
  """

  @type step_result :: {:ok, map()} | {:error, {atom(), term()}}

  @spec run([module()], map()) :: step_result()
  def run(steps, initial_context \\ %{}) when is_list(steps) and is_map(initial_context) do
    Enum.reduce_while(steps, {:ok, initial_context}, fn step_module, {:ok, ctx} ->
      case step_module.execute(ctx) do
        {:ok, updated_ctx} -> {:cont, {:ok, updated_ctx}}
        {:error, reason} -> {:halt, {:error, {step_module.name(), reason}}}
      end
    end)
  end

  @spec run_async([module()], map(), keyword()) :: step_result()
  def run_async(steps, initial_context \\ %{}, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)

    task = Task.async(fn -> run(steps, initial_context) end)

    case Task.yield(task, timeout) do
      {:ok, result} -> result
      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, {:timeout, :workflow_exceeded_deadline}}
    end
  end
end

defmodule Workflow.Steps.ValidateOrder do
  @behaviour Workflow.Step

  @impl Workflow.Step
  def name, do: :validate_order

  @impl Workflow.Step
  def execute(%{order: order} = ctx) when is_map(order) do
    with true <- Map.has_key?(order, :customer_id),
         true <- Map.has_key?(order, :line_items),
         true <- length(order.line_items) > 0 do
      {:ok, Map.put(ctx, :validation_passed, true)}
    else
      _ -> {:error, :invalid_order_structure}
    end
  end

  def execute(_ctx), do: {:error, :missing_order}
end

defmodule Workflow.Steps.ReserveInventory do
  @behaviour Workflow.Step

  @impl Workflow.Step
  def name, do: :reserve_inventory

  @impl Workflow.Step
  def execute(%{order: order} = ctx) do
    reservations =
      Enum.map(order.line_items, fn item ->
        %{sku: item.sku, quantity: item.quantity, reservation_id: generate_id()}
      end)

    {:ok, Map.put(ctx, :reservations, reservations)}
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end

defmodule Workflow.Steps.ChargePayment do
  @behaviour Workflow.Step

  @impl Workflow.Step
  def name, do: :charge_payment

  @impl Workflow.Step
  def execute(%{order: order} = ctx) do
    total = Enum.reduce(order.line_items, 0, fn i, acc -> acc + i.unit_price_cents * i.quantity end)

    case MyApp.Billing.charge(order.payment_token, total) do
      {:ok, charge_id} -> {:ok, Map.put(ctx, :charge_id, charge_id)}
      {:error, reason} -> {:error, {:payment_failed, reason}}
    end
  end
end
```
