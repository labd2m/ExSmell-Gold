**File:** `example_good_1380.md`

```elixir
defmodule Inventory.StockAggregate do
  @moduledoc """
  An event-sourced aggregate tracking stock levels for a single product variant.
  All mutations are produced as events, never applied directly to persisted state.
  """

  alias Inventory.StockAggregate.{State, Event}

  @type command ::
          {:receive_stock, pos_integer()}
          | {:reserve, String.t(), pos_integer()}
          | {:release_reservation, String.t()}
          | {:fulfill_reservation, String.t()}

  @type command_result :: {:ok, [Event.t()]} | {:error, atom()}

  @spec apply_command(State.t(), command()) :: command_result()
  def apply_command(%State{} = state, {:receive_stock, quantity}) when quantity > 0 do
    {:ok, [%Event.StockReceived{quantity: quantity, occurred_at: DateTime.utc_now()}]}
  end

  def apply_command(%State{} = state, {:reserve, reservation_id, quantity}) do
    available = State.available_quantity(state)

    cond do
      Map.has_key?(state.reservations, reservation_id) ->
        {:error, :duplicate_reservation}

      quantity > available ->
        {:error, :insufficient_stock}

      quantity <= 0 ->
        {:error, :invalid_quantity}

      true ->
        event = %Event.StockReserved{
          reservation_id: reservation_id,
          quantity: quantity,
          occurred_at: DateTime.utc_now()
        }

        {:ok, [event]}
    end
  end

  def apply_command(%State{} = state, {:release_reservation, reservation_id}) do
    if Map.has_key?(state.reservations, reservation_id) do
      {:ok, [%Event.ReservationReleased{reservation_id: reservation_id, occurred_at: DateTime.utc_now()}]}
    else
      {:error, :reservation_not_found}
    end
  end

  def apply_command(%State{} = state, {:fulfill_reservation, reservation_id}) do
    if Map.has_key?(state.reservations, reservation_id) do
      {:ok, [%Event.ReservationFulfilled{reservation_id: reservation_id, occurred_at: DateTime.utc_now()}]}
    else
      {:error, :reservation_not_found}
    end
  end

  @spec rebuild(State.t(), [Event.t()]) :: State.t()
  def rebuild(%State{} = initial, events) do
    Enum.reduce(events, initial, &State.apply_event(&2, &1))
  end
end

defmodule Inventory.StockAggregate.State do
  @moduledoc "Represents the current projected state of a stock aggregate."

  alias Inventory.StockAggregate.Event

  @enforce_keys [:product_variant_id, :on_hand, :reservations]
  defstruct [:product_variant_id, on_hand: 0, reservations: %{}]

  @type t :: %__MODULE__{
          product_variant_id: String.t(),
          on_hand: non_neg_integer(),
          reservations: %{String.t() => pos_integer()}
        }

  @spec new(String.t()) :: t()
  def new(variant_id), do: %__MODULE__{product_variant_id: variant_id, on_hand: 0, reservations: %{}}

  @spec available_quantity(t()) :: non_neg_integer()
  def available_quantity(%__MODULE__{on_hand: on_hand, reservations: reservations}) do
    reserved = reservations |> Map.values() |> Enum.sum()
    max(0, on_hand - reserved)
  end

  @spec apply_event(t(), Event.t()) :: t()
  def apply_event(%__MODULE__{on_hand: qty} = state, %Event.StockReceived{quantity: n}) do
    %{state | on_hand: qty + n}
  end

  def apply_event(%__MODULE__{reservations: r} = state, %Event.StockReserved{reservation_id: id, quantity: q}) do
    %{state | reservations: Map.put(r, id, q)}
  end

  def apply_event(%__MODULE__{reservations: r} = state, %Event.ReservationReleased{reservation_id: id}) do
    %{state | reservations: Map.delete(r, id)}
  end

  def apply_event(%__MODULE__{on_hand: qty, reservations: r} = state, %Event.ReservationFulfilled{reservation_id: id}) do
    fulfilled_qty = Map.get(r, id, 0)
    %{state | on_hand: qty - fulfilled_qty, reservations: Map.delete(r, id)}
  end
end

defmodule Inventory.StockAggregate.Event do
  @moduledoc "Event structs emitted by the stock aggregate."

  defmodule StockReceived do
    @enforce_keys [:quantity, :occurred_at]
    defstruct [:quantity, :occurred_at]
    @type t :: %__MODULE__{quantity: pos_integer(), occurred_at: DateTime.t()}
  end

  defmodule StockReserved do
    @enforce_keys [:reservation_id, :quantity, :occurred_at]
    defstruct [:reservation_id, :quantity, :occurred_at]
    @type t :: %__MODULE__{reservation_id: String.t(), quantity: pos_integer(), occurred_at: DateTime.t()}
  end

  defmodule ReservationReleased do
    @enforce_keys [:reservation_id, :occurred_at]
    defstruct [:reservation_id, :occurred_at]
    @type t :: %__MODULE__{reservation_id: String.t(), occurred_at: DateTime.t()}
  end

  defmodule ReservationFulfilled do
    @enforce_keys [:reservation_id, :occurred_at]
    defstruct [:reservation_id, :occurred_at]
    @type t :: %__MODULE__{reservation_id: String.t(), occurred_at: DateTime.t()}
  end

  @type t :: StockReceived.t() | StockReserved.t() | ReservationReleased.t() | ReservationFulfilled.t()
end
```
