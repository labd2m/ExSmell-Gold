```elixir
defmodule Catalog.PriceIndexer do
  @moduledoc """
  Maintains a fast in-memory price index over the active product catalogue.
  The index supports range queries by price without hitting the database
  on every request. It is rebuilt from the database on startup and updated
  incrementally via a PubSub listener. Reads go directly to ETS;
  writes are serialised through the GenServer.
  """

  use GenServer

  @table :price_index
  @topic "catalog:product_updates"

  @type product_id :: String.t()
  @type price_cents :: non_neg_integer()

  @doc "Starts the price indexer."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns all product IDs whose price falls within `[min_cents, max_cents]`.
  Both bounds are inclusive. Pass `nil` to omit a bound.
  """
  @spec products_in_range(price_cents() | nil, price_cents() | nil) :: [product_id()]
  def products_in_range(min_cents, max_cents) do
    :ets.tab2list(@table)
    |> Enum.filter(fn {_id, price} ->
      (is_nil(min_cents) or price >= min_cents) and
        (is_nil(max_cents) or price <= max_cents)
    end)
    |> Enum.map(fn {id, _price} -> id end)
  end

  @doc "Returns the current indexed price for `product_id`, or `nil` if absent."
  @spec price_for(product_id()) :: price_cents() | nil
  def price_for(product_id) when is_binary(product_id) do
    case :ets.lookup(@table, product_id) do
      [{^product_id, price}] -> price
      [] -> nil
    end
  end

  @doc "Returns the count of products currently in the index."
  @spec size() :: non_neg_integer()
  def size, do: :ets.info(@table, :size)

  @doc "Forces a full rebuild of the index from the database."
  @spec rebuild() :: :ok
  def rebuild, do: GenServer.cast(__MODULE__, :rebuild)

  @impl GenServer
  def init(opts) do
    :ets.new(@table, [:set, :protected, :named_table, read_concurrency: true])
    Phoenix.PubSub.subscribe(MyApp.PubSub, @topic)
    load_all = Keyword.get(opts, :load_on_start, true)
    if load_all, do: send(self(), :initial_load)
    {:ok, %{}}
  end

  @impl GenServer
  def handle_cast(:rebuild, state) do
    :ets.delete_all_objects(@table)
    load_from_db()
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:initial_load, state) do
    load_from_db()
    {:noreply, state}
  end

  def handle_info({:product_updated, %{id: id, price_cents: price, active: true}}, state) do
    :ets.insert(@table, {id, price})
    {:noreply, state}
  end

  def handle_info({:product_updated, %{id: id, active: false}}, state) do
    :ets.delete(@table, id)
    {:noreply, state}
  end

  def handle_info({:product_deleted, %{id: id}}, state) do
    :ets.delete(@table, id)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp load_from_db do
    import Ecto.Query

    from(p in "products",
      where: p.active == true,
      select: {p.id, p.price_cents}
    )
    |> MyApp.Repo.all()
    |> Enum.each(fn {id, price} -> :ets.insert(@table, {id, price}) end)
  end
end
```
