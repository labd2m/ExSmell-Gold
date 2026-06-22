```elixir
defmodule Fulfillment.OrderStateMachine do
  @moduledoc """
  Pure functional state machine governing order lifecycle transitions.

  Defines valid state transitions and the side-effect-free business rules
  enforced at each boundary. All mutation concerns are delegated to the
  calling context.
  """

  @type order_state ::
          :pending
          | :confirmed
          | :picking
          | :packed
          | :shipped
          | :delivered
          | :cancelled

  @type order :: %{
          id: String.t(),
          state: order_state(),
          line_items: [map()],
          shipping_address: map() | nil,
          tracking_number: String.t() | nil
        }

  @type transition_error ::
          {:error, :invalid_transition}
          | {:error, :missing_shipping_address}
          | {:error, :no_line_items}
          | {:error, :tracking_number_required}

  @doc """
  Attempts to advance an order to its next logical state.

  Returns `{:ok, updated_order}` when the transition is valid and all
  business rules pass, or a tagged error tuple otherwise.
  """
  @spec transition(order(), order_state()) :: {:ok, order()} | transition_error()
  def transition(%{state: :pending} = order, :confirmed) do
    with :ok <- validate_has_line_items(order),
         :ok <- validate_has_shipping_address(order) do
      {:ok, %{order | state: :confirmed}}
    end
  end

  def transition(%{state: :confirmed} = order, :picking) do
    {:ok, %{order | state: :picking}}
  end

  def transition(%{state: :picking} = order, :packed) do
    {:ok, %{order | state: :packed}}
  end

  def transition(%{state: :packed} = order, :shipped) do
    case validate_has_tracking_number(order) do
      :ok -> {:ok, %{order | state: :shipped}}
      error -> error
    end
  end

  def transition(%{state: :shipped} = order, :delivered) do
    {:ok, %{order | state: :delivered}}
  end

  def transition(%{state: state} = order, :cancelled)
      when state in [:pending, :confirmed, :picking] do
    {:ok, %{order | state: :cancelled}}
  end

  def transition(_order, _target_state) do
    {:error, :invalid_transition}
  end

  @doc """
  Returns true if the given state transition is structurally permitted.

  Does not evaluate business rule preconditions.
  """
  @spec valid_transition?(order_state(), order_state()) :: boolean()
  def valid_transition?(from, to) do
    to in allowed_next_states(from)
  end

  @doc """
  Returns the list of reachable next states from the given state.
  """
  @spec allowed_next_states(order_state()) :: [order_state()]
  def allowed_next_states(:pending), do: [:confirmed, :cancelled]
  def allowed_next_states(:confirmed), do: [:picking, :cancelled]
  def allowed_next_states(:picking), do: [:packed, :cancelled]
  def allowed_next_states(:packed), do: [:shipped]
  def allowed_next_states(:shipped), do: [:delivered]
  def allowed_next_states(:delivered), do: []
  def allowed_next_states(:cancelled), do: []

  defp validate_has_line_items(%{line_items: [_ | _]}), do: :ok
  defp validate_has_line_items(_order), do: {:error, :no_line_items}

  defp validate_has_shipping_address(%{shipping_address: addr}) when is_map(addr) do
    if map_size(addr) > 0, do: :ok, else: {:error, :missing_shipping_address}
  end

  defp validate_has_shipping_address(_order), do: {:error, :missing_shipping_address}

  defp validate_has_tracking_number(%{tracking_number: num}) when is_binary(num) and num != "" do
    :ok
  end

  defp validate_has_tracking_number(_order), do: {:error, :tracking_number_required}
end
```
