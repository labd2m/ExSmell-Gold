# Annotated Example 11 — Large Messages

| Field                  | Value                                                                        |
|------------------------|------------------------------------------------------------------------------|
| **Smell name**         | Large messages                                                               |
| **Expected location**  | `Recommendations.Engine.request/2`                                          |
| **Affected function(s)**| `request/2`, `handle_call/3` (GenServer)                                   |
| **Explanation**        | The recommendation engine is called synchronously with a full order history for all customers — a list of order maps each carrying multiple line items, shipping addresses, and payment snapshots. The engine is a GenServer, so the calling process blocks while the entire structure is deep-copied into the engine's heap. Because recommendation requests are made on each page load for logged-in users, this large synchronous copy becomes a latency bottleneck on every request. |

```elixir
defmodule Recommendations.LineItem do
  defstruct [:sku, :name, :qty, :unit_price_cents, :category, :attributes]
end

defmodule Recommendations.ShippingAddress do
  defstruct [:street, :city, :state, :country, :postal_code]
end

defmodule Recommendations.PaymentSnapshot do
  defstruct [:method, :last_four, :amount_cents, :status, :captured_at]
end

defmodule Recommendations.Order do
  @enforce_keys [:id, :customer_id, :placed_at]
  defstruct [
    :id,
    :customer_id,
    :placed_at,
    :status,
    :line_items,
    :shipping_address,
    :payment,
    :promo_codes,
    :notes
  ]
end

defmodule Recommendations.OrderStore do
  @moduledoc "Simulates fetching full order history for all active customers."

  @spec all_recent(non_neg_integer()) :: list(Recommendations.Order.t())
  def all_recent(limit) do
    Enum.map(1..limit, fn i ->
      %Recommendations.Order{
        id: "ORD-#{i}",
        customer_id: "CUST-#{rem(i, 10_000)}",
        placed_at: DateTime.utc_now() |> DateTime.add(-rem(i, 90) * 86_400),
        status: Enum.random([:delivered, :shipped, :cancelled]),
        line_items: Enum.map(1..6, fn j ->
          %Recommendations.LineItem{
            sku: "SKU-#{j + rem(i, 500)}",
            name: "Product #{j + rem(i, 500)}",
            qty: rem(j, 5) + 1,
            unit_price_cents: j * 1_000 + i,
            category: Enum.random(["books", "electronics", "clothing", "food"]),
            attributes: %{color: "blue", size: "M", weight_g: 300}
          }
        end),
        shipping_address: %Recommendations.ShippingAddress{
          street: "Rua #{i}",
          city: "São Paulo",
          state: "SP",
          country: "BR",
          postal_code: "0#{String.pad_leading("#{rem(i, 100_000)}", 7, "0")}"
        },
        payment: %Recommendations.PaymentSnapshot{
          method: "credit_card",
          last_four: String.pad_leading("#{rem(i, 10_000)}", 4, "0"),
          amount_cents: Enum.random(5_000..500_000),
          status: :captured,
          captured_at: DateTime.utc_now()
        },
        promo_codes: if(rem(i, 10) == 0, do: ["PROMO10"], else: []),
        notes: nil
      }
    end)
  end
end

defmodule Recommendations.Engine do
  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{model: %{}}, opts)
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:compute, orders, customer_id}, _from, state) do
    customer_orders =
      Enum.filter(orders, &(&1.customer_id == customer_id))

    top_categories =
      customer_orders
      |> Enum.flat_map(& &1.line_items)
      |> Enum.frequencies_by(& &1.category)
      |> Enum.sort_by(fn {_, v} -> -v end)
      |> Enum.take(3)
      |> Enum.map(fn {cat, _} -> cat end)

    {:reply, {:ok, top_categories}, state}
  end
end

defmodule Recommendations.RequestHandler do
  @moduledoc "Handles per-request recommendation lookups."

  require Logger

  @spec request(pid(), String.t()) :: {:ok, list(String.t())} | {:error, term()}
  def request(engine_pid, customer_id) do
    Logger.debug("Fetching order history for recommendation — customer #{customer_id}")

    all_orders = Recommendations.OrderStore.all_recent(50_000)

    # VALIDATION: SMELL START - Large messages
    # VALIDATION: This is a smell because `all_orders` is a list of 50 000
    # Order structs, each containing 6 LineItem structs, a ShippingAddress,
    # a PaymentSnapshot, and various string fields. Sending this immense
    # collection to the Engine process via GenServer.call/2 forces a full
    # heap copy before the engine can begin filtering. Because this function
    # is invoked synchronously on the request path, every page load for a
    # logged-in user stalls for the duration of the data copy — directly
    # impacting user-facing response time at scale.
    result = GenServer.call(engine_pid, {:compute, all_orders, customer_id}, :infinity)
    # VALIDATION: SMELL END

    case result do
      {:ok, categories} ->
        Logger.debug("Recommendations computed: #{inspect(categories)}")
        {:ok, categories}

      error ->
        Logger.warn("Recommendation error: #{inspect(error)}")
        {:error, error}
    end
  end
end
```
