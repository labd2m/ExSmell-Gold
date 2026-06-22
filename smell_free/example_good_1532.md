```elixir
defmodule Orders.Aggregate do
  @moduledoc """
  Pure functional aggregate for the Order domain.

  State is reconstructed by replaying a sequence of domain events.
  No side effects are performed here; command handlers return event lists.
  """

  alias Orders.Aggregate.State
  alias Orders.Events.{OrderPlaced, ItemAdded, OrderCancelled, OrderShipped}

  @type command ::
          {:place_order, map()}
          | {:add_item, map()}
          | {:cancel_order, String.t()}
          | {:ship_order, String.t()}

  @type event :: OrderPlaced.t() | ItemAdded.t() | OrderCancelled.t() | OrderShipped.t()

  @doc """
  Rebuilds aggregate state from a list of previously persisted events.
  """
  @spec rebuild([event()]) :: State.t()
  def rebuild(events) when is_list(events) do
    Enum.reduce(events, State.empty(), &apply_event/2)
  end

  @doc """
  Validates and executes a command against current state, returning new events.
  """
  @spec execute(State.t(), command()) :: {:ok, [event()]} | {:error, String.t()}
  def execute(%State{status: :new}, {:place_order, params}) do
    with {:ok, validated} <- validate_place_order(params) do
      {:ok, [OrderPlaced.new(validated)]}
    end
  end

  def execute(%State{status: :active} = state, {:add_item, params}) do
    with {:ok, validated} <- validate_add_item(params, state) do
      {:ok, [ItemAdded.new(validated)]}
    end
  end

  def execute(%State{status: :active}, {:cancel_order, reason}) when is_binary(reason) do
    {:ok, [OrderCancelled.new(%{reason: reason, cancelled_at: DateTime.utc_now()})]}
  end

  def execute(%State{status: :active}, {:ship_order, tracking_number}) when is_binary(tracking_number) do
    {:ok, [OrderShipped.new(%{tracking_number: tracking_number, shipped_at: DateTime.utc_now()})]}
  end

  def execute(%State{status: status}, {cmd, _}) do
    {:error, "command #{cmd} not allowed in status #{status}"}
  end

  # --- event application ---

  defp apply_event(%OrderPlaced{} = e, state) do
    %State{state | id: e.order_id, customer_id: e.customer_id, status: :active, items: []}
  end

  defp apply_event(%ItemAdded{} = e, state) do
    %State{state | items: [e.item | state.items]}
  end

  defp apply_event(%OrderCancelled{}, state) do
    %State{state | status: :cancelled}
  end

  defp apply_event(%OrderShipped{tracking_number: tn}, state) do
    %State{state | status: :shipped, tracking_number: tn}
  end

  # --- command validators ---

  defp validate_place_order(%{customer_id: cid, currency: cur})
       when is_binary(cid) and is_binary(cur) do
    {:ok, %{order_id: UUID.uuid4(), customer_id: cid, currency: cur, placed_at: DateTime.utc_now()}}
  end

  defp validate_place_order(_), do: {:error, "invalid order params"}

  defp validate_add_item(%{sku: sku, quantity: qty, unit_price_cents: price}, _state)
       when is_binary(sku) and is_integer(qty) and qty > 0 and is_integer(price) and price > 0 do
    {:ok, %{sku: sku, quantity: qty, unit_price_cents: price}}
  end

  defp validate_add_item(_, _), do: {:error, "invalid item params"}
end

defmodule Orders.Aggregate.State do
  @moduledoc false

  @enforce_keys []
  defstruct id: nil,
            customer_id: nil,
            status: :new,
            items: [],
            tracking_number: nil

  @type t :: %__MODULE__{
          id: String.t() | nil,
          customer_id: String.t() | nil,
          status: :new | :active | :cancelled | :shipped,
          items: list(),
          tracking_number: String.t() | nil
        }

  @spec empty() :: t()
  def empty, do: %__MODULE__{}
end
```
