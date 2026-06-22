```elixir
defmodule Commerce.PriceLocalizationContext do
  @moduledoc """
  Localises product prices for different markets. Each market definition
  specifies a currency, a multiplier applied to the base price, and an
  optional rounding rule. Localised prices are cached in ETS for fast
  storefront rendering and invalidated when base prices change via PubSub.
  """

  use GenServer

  @table :localised_prices
  @topic "catalog:product_updates"

  @type market :: String.t()
  @type product_id :: String.t()
  @type localised_price :: %{
          market: market(),
          currency: String.t(),
          amount_cents: non_neg_integer(),
          formatted: String.t()
        }

  @markets Application.compile_env(:my_app, :price_markets, %{
    "US" => %{currency: "USD", multiplier: 1.0, rounding: :nearest_cent},
    "GB" => %{currency: "GBP", multiplier: 0.79, rounding: :nearest_five},
    "EU" => %{currency: "EUR", multiplier: 0.92, rounding: :nearest_cent},
    "AU" => %{currency: "AUD", multiplier: 1.52, rounding: :nearest_cent}
  })

  @doc "Starts the price localisation context."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the localised price for `product_id` in `market`."
  @spec price_for(product_id(), market()) :: {:ok, localised_price()} | {:error, :unknown_market | :not_found}
  def price_for(product_id, market) when is_binary(product_id) and is_binary(market) do
    case Map.get(@markets, market) do
      nil -> {:error, :unknown_market}
      market_def ->
        case :ets.lookup(@table, {product_id, market}) do
          [{{^product_id, ^market}, price}] -> {:ok, price}
          [] -> compute_and_cache(product_id, market, market_def)
        end
    end
  end

  @doc "Returns prices for `product_id` across all configured markets."
  @spec all_markets(product_id()) :: [localised_price()]
  def all_markets(product_id) when is_binary(product_id) do
    @markets
    |> Map.keys()
    |> Enum.flat_map(fn market ->
      case price_for(product_id, market) do
        {:ok, price} -> [price]
        _ -> []
      end
    end)
  end

  @doc "Returns all configured market codes."
  @spec available_markets() :: [market()]
  def available_markets, do: Map.keys(@markets)

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:set, :protected, :named_table, read_concurrency: true])
    Phoenix.PubSub.subscribe(MyApp.PubSub, @topic)
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info({:product_updated, %{id: product_id}}, state) do
    @markets
    |> Map.keys()
    |> Enum.each(fn market -> :ets.delete(@table, {product_id, market}) end)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp compute_and_cache(product_id, market, market_def) do
    import Ecto.Query

    case MyApp.Repo.one(from(p in "products", where: p.id == ^product_id, select: p.price_cents)) do
      nil ->
        {:error, :not_found}

      base_cents ->
        raw = base_cents * market_def.multiplier
        rounded = apply_rounding(raw, market_def.rounding)
        price = %{
          market: market,
          currency: market_def.currency,
          amount_cents: rounded,
          formatted: format_price(rounded, market_def.currency)
        }
        :ets.insert(@table, {{product_id, market}, price})
        {:ok, price}
    end
  end

  defp apply_rounding(amount, :nearest_cent), do: round(amount)
  defp apply_rounding(amount, :nearest_five), do: round(amount / 5) * 5

  defp format_price(cents, currency) do
    major = div(cents, 100)
    minor = rem(cents, 100) |> Integer.to_string() |> String.pad_leading(2, "0")
    "#{major}.#{minor} #{currency}"
  end
end
```
