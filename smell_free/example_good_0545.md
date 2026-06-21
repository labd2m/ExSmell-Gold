# File: `example_good_545.md`

```elixir
defmodule Commerce.WishlistManager do
  @moduledoc """
  GenServer managing per-user product wishlists with a configurable
  maximum item count and optional move-to-cart integration.

  Wishlists are held in memory and optionally persisted via a
  persistence adapter on mutation, keeping read latency low while
  ensuring durability on writes.
  """

  use GenServer

  require Logger

  @default_max_items 100

  @type user_id :: String.t()
  @type sku :: String.t()

  @type wishlist_item :: %{
          sku: sku(),
          added_at: DateTime.t(),
          note: String.t() | nil
        }

  @type opts :: [
          persistence: module() | nil,
          max_items: pos_integer()
        ]

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Adds `sku` to `user_id`'s wishlist with an optional personal note.

  Returns `:ok`, `{:error, :already_present}`, or `{:error, :at_capacity}`.
  """
  @spec add(user_id(), sku(), String.t() | nil) ::
          :ok | {:error, :already_present | :at_capacity}
  def add(user_id, sku, note \\ nil)
      when is_binary(user_id) and is_binary(sku) do
    GenServer.call(__MODULE__, {:add, user_id, sku, note})
  end

  @doc """
  Removes `sku` from `user_id`'s wishlist.

  Returns `:ok` unconditionally.
  """
  @spec remove(user_id(), sku()) :: :ok
  def remove(user_id, sku) when is_binary(user_id) and is_binary(sku) do
    GenServer.cast(__MODULE__, {:remove, user_id, sku})
  end

  @doc """
  Returns all wishlist items for `user_id`, ordered by most recently added.
  """
  @spec list(user_id()) :: [wishlist_item()]
  def list(user_id) when is_binary(user_id) do
    GenServer.call(__MODULE__, {:list, user_id})
  end

  @doc """
  Returns `true` when `sku` is present in `user_id`'s wishlist.
  """
  @spec member?(user_id(), sku()) :: boolean()
  def member?(user_id, sku) when is_binary(user_id) and is_binary(sku) do
    GenServer.call(__MODULE__, {:member?, user_id, sku})
  end

  @doc """
  Moves `sku` from `user_id`'s wishlist to their cart via a cart
  module. Removes the item from the wishlist on success.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec move_to_cart(user_id(), sku(), module()) :: :ok | {:error, term()}
  def move_to_cart(user_id, sku, cart_module)
      when is_binary(user_id) and is_binary(sku) do
    GenServer.call(__MODULE__, {:move_to_cart, user_id, sku, cart_module})
  end

  @doc """
  Returns the count of items across all active wishlists.
  """
  @spec total_item_count() :: non_neg_integer()
  def total_item_count do
    GenServer.call(__MODULE__, :total_item_count)
  end

  @impl GenServer
  def init(opts) do
    persistence = Keyword.get(opts, :persistence)
    max_items = Keyword.get(opts, :max_items, @default_max_items)
    wishlists = if persistence, do: persistence.load_all(), else: %{}
    {:ok, %{wishlists: wishlists, persistence: persistence, max_items: max_items}}
  end

  @impl GenServer
  def handle_call({:add, user_id, sku, note}, _from, state) do
    items = Map.get(state.wishlists, user_id, [])

    cond do
      Enum.any?(items, &(&1.sku == sku)) ->
        {:reply, {:error, :already_present}, state}

      length(items) >= state.max_items ->
        {:reply, {:error, :at_capacity}, state}

      true ->
        item = %{sku: sku, added_at: DateTime.utc_now(), note: note}
        new_items = [item | items]
        new_state = put_in(state, [:wishlists, user_id], new_items)
        persist(new_state.persistence, user_id, new_items)
        {:reply, :ok, new_state}
    end
  end

  @impl GenServer
  def handle_call({:list, user_id}, _from, state) do
    {:reply, Map.get(state.wishlists, user_id, []), state}
  end

  @impl GenServer
  def handle_call({:member?, user_id, sku}, _from, state) do
    items = Map.get(state.wishlists, user_id, [])
    {:reply, Enum.any?(items, &(&1.sku == sku)), state}
  end

  @impl GenServer
  def handle_call({:move_to_cart, user_id, sku, cart_module}, _from, state) do
    items = Map.get(state.wishlists, user_id, [])

    case Enum.find(items, &(&1.sku == sku)) do
      nil ->
        {:reply, {:error, :not_in_wishlist}, state}

      _item ->
        case cart_module.add_item(user_id, sku, 1) do
          {:ok, _} ->
            new_items = Enum.reject(items, &(&1.sku == sku))
            new_state = put_in(state, [:wishlists, user_id], new_items)
            persist(new_state.persistence, user_id, new_items)
            {:reply, :ok, new_state}

          {:error, _reason} = error ->
            {:reply, error, state}
        end
    end
  end

  @impl GenServer
  def handle_call(:total_item_count, _from, state) do
    count = state.wishlists |> Map.values() |> Enum.sum_by(&length/1)
    {:reply, count, state}
  end

  @impl GenServer
  def handle_cast({:remove, user_id, sku}, state) do
    items = Map.get(state.wishlists, user_id, [])
    new_items = Enum.reject(items, &(&1.sku == sku))
    new_state = put_in(state, [:wishlists, user_id], new_items)
    persist(new_state.persistence, user_id, new_items)
    {:noreply, new_state}
  end

  defp persist(nil, _user_id, _items), do: :ok
  defp persist(mod, user_id, items), do: mod.save(user_id, items)
end
```
