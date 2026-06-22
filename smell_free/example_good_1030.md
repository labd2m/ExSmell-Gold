```elixir
defmodule Commerce.OrderProjection do
  @moduledoc """
  Maintains a fast read-side projection of order data for the customer
  dashboard. The projection is built from domain events published to
  PubSub, so it reflects the latest order state without requiring
  direct database queries on every page load. Data is stored in ETS and
  survives short node restarts via a warm-start reload from the database.
  """

  use GenServer

  require Logger

  @table :order_projection
  @topic "domain:events"

  @type customer_id :: String.t()
  @type order_summary :: %{
          id: String.t(),
          status: String.t(),
          total_cents: non_neg_integer(),
          currency: String.t(),
          placed_at: String.t(),
          item_count: non_neg_integer()
        }

  @doc "Starts the order projection worker."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns all order summaries for `customer_id`, newest first."
  @spec orders_for(customer_id()) :: [order_summary()]
  def orders_for(customer_id) when is_binary(customer_id) do
    @table
    |> :ets.match_object({:"$1", %{customer_id: customer_id}})
    |> Enum.map(fn {_key, summary} -> summary end)
    |> Enum.sort_by(& &1.placed_at, :desc)
  end

  @doc "Returns a single order summary by ID, or `nil` when not found."
  @spec find(String.t()) :: order_summary() | nil
  def find(order_id) when is_binary(order_id) do
    case :ets.lookup(@table, order_id) do
      [{^order_id, summary}] -> summary
      [] -> nil
    end
  end

  @doc "Returns the total count of orders in the projection."
  @spec total_count() :: non_neg_integer()
  def total_count, do: :ets.info(@table, :size)

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:set, :protected, :named_table, read_concurrency: true])
    Phoenix.PubSub.subscribe(MyApp.PubSub, @topic)
    send(self(), :warm_start)
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info(:warm_start, state) do
    load_from_db()
    {:noreply, state}
  end

  def handle_info({:domain_event, %{"type" => "order.placed", "payload" => p}}, state) do
    summary = %{
      id: p["order_id"],
      customer_id: p["customer_id"],
      status: "confirmed",
      total_cents: p["total_cents"],
      currency: p["currency"] || "USD",
      placed_at: p["placed_at"],
      item_count: length(p["line_items"] || [])
    }
    :ets.insert(@table, {p["order_id"], summary})
    {:noreply, state}
  end

  def handle_info({:domain_event, %{"type" => "order.status_changed", "payload" => p}}, state) do
    case :ets.lookup(@table, p["order_id"]) do
      [{id, summary}] -> :ets.insert(@table, {id, %{summary | status: p["status"]}})
      [] -> :ok
    end
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp load_from_db do
    import Ecto.Query

    from(o in "orders",
      where: o.status != "cancelled",
      select: map(o, [:id, :customer_id, :status, :total_cents, :currency, :inserted_at])
    )
    |> MyApp.Repo.all()
    |> Enum.each(fn order ->
      summary = %{
        id: order.id,
        customer_id: order.customer_id,
        status: order.status,
        total_cents: order.total_cents,
        currency: order.currency || "USD",
        placed_at: DateTime.to_iso8601(order.inserted_at),
        item_count: 0
      }
      :ets.insert(@table, {order.id, summary})
    end)

    Logger.info("[OrderProjection] Warm start complete: #{:ets.info(@table, :size)} order(s) loaded")
  rescue
    e -> Logger.warning("[OrderProjection] Warm start failed: #{Exception.message(e)}")
  end
end
```
