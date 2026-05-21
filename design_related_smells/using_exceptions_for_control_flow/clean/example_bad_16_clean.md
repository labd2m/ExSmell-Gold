```elixir
defmodule Catalog.Product do
  @moduledoc "Represents a product in the catalog."

  @enforce_keys [:id, :name, :status, :category]
  defstruct [:id, :name, :status, :category, :sku, :tags, :weight_kg]

  @type status :: :active | :discontinued | :draft | :archived
end

defmodule Catalog.Price do
  @moduledoc "A product price in a specific currency and context."

  @enforce_keys [:product_id, :currency, :amount, :price_type]
  defstruct [:product_id, :currency, :amount, :price_type, :valid_from, :valid_until]
end

defmodule Catalog.ProductRepository do
  @moduledoc "In-memory product catalogue."

  alias Catalog.Product

  @products %{
    "prod_001" => %Product{id: "prod_001", name: "Ergonomic Chair", status: :active, category: "furniture", sku: "ERG-001"},
    "prod_002" => %Product{id: "prod_002", name: "Standing Desk", status: :active, category: "furniture", sku: "DSK-002"},
    "prod_003" => %Product{id: "prod_003", name: "CRT Monitor", status: :discontinued, category: "electronics", sku: "MON-003"}
  }

  def find(id), do: Map.fetch(@products, id)
end

defmodule Catalog.PriceRepository do
  @moduledoc "In-memory price list."

  alias Catalog.Price

  @prices [
    %Price{product_id: "prod_001", currency: "USD", amount: 349.99, price_type: :retail},
    %Price{product_id: "prod_001", currency: "EUR", amount: 319.99, price_type: :retail},
    %Price{product_id: "prod_002", currency: "USD", amount: 599.99, price_type: :retail}
  ]

  def find_for(product_id, currency, price_type) do
    Enum.find(@prices, fn p ->
      p.product_id == product_id and p.currency == currency and p.price_type == price_type
    end)
  end
end

defmodule Catalog.PriceEngine do
  @moduledoc """
  Resolves the effective price for a product given a currency and pricing context.
  Applies any active promotional overrides before returning the final amount.
  """

  alias Catalog.{PriceRepository, ProductRepository}
  require Logger

  @supported_currencies ~w[USD EUR GBP BRL CAD]
  @supported_price_types [:retail, :wholesale, :member]

  def resolve_price(product_id, currency, price_type \\ :retail)
      when is_binary(product_id) and is_binary(currency) do
    unless currency in @supported_currencies do
      raise RuntimeError,
        message:
          "Currency '#{currency}' is not supported. " <>
            "Supported: #{Enum.join(@supported_currencies, ", ")}"
    end

    unless price_type in @supported_price_types do
      raise RuntimeError,
        message: "Price type '#{price_type}' is not a recognised pricing context"
    end

    case ProductRepository.find(product_id) do
      :error ->
        raise RuntimeError,
          message: "Product '#{product_id}' does not exist in the catalogue"

      {:ok, product} ->
        if product.status == :discontinued do
          raise RuntimeError,
            message:
              "Product '#{product.name}' (#{product_id}) is discontinued and cannot be priced"
        end

        case PriceRepository.find_for(product_id, currency, price_type) do
          nil ->
            raise RuntimeError,
              message:
                "No #{price_type} price found for product '#{product_id}' in #{currency}. " <>
                  "Contact the catalogue team to add pricing for this combination."

          price ->
            Logger.debug("Resolved #{price_type} price for #{product_id}: #{price.amount} #{currency}")

            %{
              product_id: product_id,
              product_name: product.name,
              currency: currency,
              amount: price.amount,
              price_type: price_type
            }
        end
    end
  end
end

defmodule Catalog.CartPricer do
  @moduledoc """
  Prices each item in a shopping cart by resolving the current catalogue price.
  Accumulates pricing errors per line rather than aborting the whole cart.
  """

  alias Catalog.PriceEngine
  require Logger

  def price_items(cart_items, currency) when is_list(cart_items) and is_binary(currency) do
    Enum.reduce(cart_items, %{priced: [], errors: []}, fn item, acc ->
      # Client forced to use try/rescue because PriceEngine.resolve_price/3 raises
      # on all failure conditions instead of returning {:error, reason}.
      try do
        resolved = PriceEngine.resolve_price(item.product_id, currency)

        line = %{
          product_id: item.product_id,
          quantity: item.quantity,
          unit_price: resolved.amount,
          line_total: resolved.amount * item.quantity,
          currency: currency
        }

        Map.update!(acc, :priced, &[line | &1])
      rescue
        e in RuntimeError ->
          Logger.warning("Could not price item #{item.product_id}: #{e.message}")
          Map.update!(acc, :errors, &[%{product_id: item.product_id, reason: e.message} | &1])
      end
    end)
  end

  def cart_total(%{priced: lines}) do
    Enum.reduce(lines, 0.0, fn line, acc -> acc + line.line_total end)
  end
end
```
