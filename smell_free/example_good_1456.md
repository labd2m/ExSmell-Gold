```elixir
defmodule Cart.Item do
  @moduledoc """
  Represents a single line item within a shopping cart session.
  """

  @type t :: %__MODULE__{
          sku: String.t(),
          name: String.t(),
          unit_price_cents: pos_integer(),
          quantity: pos_integer()
        }

  defstruct [:sku, :name, :unit_price_cents, :quantity]

  @spec line_total(%__MODULE__{}) :: pos_integer()
  def line_total(%__MODULE__{unit_price_cents: price, quantity: qty}), do: price * qty
end

defmodule Cart.Session do
  use GenServer

  alias Cart.Item

  @moduledoc """
  Manages an isolated shopping cart session as a supervised process.
  Each session is keyed by a unique session token and resides under
  the `Cart.SessionSupervisor`.
  """

  @type state :: %{token: String.t(), items: %{String.t() => Item.t()}}
  @type checkout_result :: %{items: [Item.t()], total_cents: non_neg_integer()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    token = Keyword.fetch!(opts, :token)
    GenServer.start_link(__MODULE__, token, name: via(token))
  end

  @spec add_item(String.t(), Item.t()) :: :ok
  def add_item(token, %Item{} = item) do
    GenServer.cast(via(token), {:add, item})
  end

  @spec remove_item(String.t(), String.t()) :: :ok
  def remove_item(token, sku) when is_binary(sku) do
    GenServer.cast(via(token), {:remove, sku})
  end

  @spec checkout(String.t()) :: {:ok, checkout_result()} | {:error, :empty_cart}
  def checkout(token) do
    GenServer.call(via(token), :checkout)
  end

  @spec item_count(String.t()) :: non_neg_integer()
  def item_count(token) do
    GenServer.call(via(token), :item_count)
  end

  @impl GenServer
  def init(token) do
    {:ok, %{token: token, items: %{}}}
  end

  @impl GenServer
  def handle_cast({:add, item}, state) do
    updated_items =
      Map.update(state.items, item.sku, item, fn existing ->
        %{existing | quantity: existing.quantity + item.quantity}
      end)

    {:noreply, %{state | items: updated_items}}
  end

  def handle_cast({:remove, sku}, state) do
    {:noreply, %{state | items: Map.delete(state.items, sku)}}
  end

  @impl GenServer
  def handle_call(:checkout, _from, %{items: items} = state) when map_size(items) == 0 do
    {:reply, {:error, :empty_cart}, state}
  end

  def handle_call(:checkout, _from, state) do
    item_list = Map.values(state.items)
    total = Enum.reduce(item_list, 0, fn item, acc -> acc + Item.line_total(item) end)
    result = %{items: item_list, total_cents: total}
    {:reply, {:ok, result}, %{state | items: %{}}}
  end

  def handle_call(:item_count, _from, state) do
    total = Enum.reduce(state.items, 0, fn {_, item}, acc -> acc + item.quantity end)
    {:reply, total, state}
  end

  defp via(token), do: {:via, Registry, {Cart.Registry, token}}
end
```
