```elixir
defmodule Catalog.ProductVariantManager do
  @moduledoc """
  Manages product variant creation, pricing updates, and availability
  matrix generation for the e-commerce catalog system. Supports
  multi-dimensional variants (colour × size).
  """

  require Logger

  alias Catalog.Repo
  alias Catalog.Schema.{Product, ProductVariant}

  @valid_sizes ~w(XS S M L XL XXL ONE_SIZE)
  @valid_colours ~w(BLACK WHITE RED BLUE GREEN YELLOW NAVY GREY PINK)
  @default_stock 0


  @spec create_variant(Product.t(), String.t(), String.t()) ::
          {:ok, ProductVariant.t()} | {:error, term()}
  def create_variant(%Product{} = product, colour, size)
      when is_binary(colour) and is_binary(size) do
    with :ok <- validate_colour(colour),
         :ok <- validate_size(size),
         false <- variant_exists?(product, colour, size) do
      sku = "#{product.base_sku}-#{String.upcase(colour)}-#{String.upcase(size)}"
      display_name = "#{product.name} — #{String.capitalize(colour)} / #{size}"

      attrs = %{
        product_id: product.id,
        colour: String.upcase(colour),
        size: String.upcase(size),
        sku: sku,
        display_name: display_name,
        price: product.base_price,
        stock_quantity: @default_stock,
        active: true
      }

      case %ProductVariant{} |> ProductVariant.changeset(attrs) |> Repo.insert() do
        {:ok, variant} ->
          Logger.info("Variant created: sku=#{sku} product=#{product.id}")
          {:ok, variant}

        {:error, cs} ->
          {:error, cs}
      end
    else
      true -> {:error, {:variant_already_exists, colour, size}}
    end
  end

  @spec update_pricing(Product.t(), String.t(), String.t()) ::
          {:ok, ProductVariant.t()} | {:error, term()}
  def update_pricing(%Product{} = product, colour, size)
      when is_binary(colour) and is_binary(size) do
    with :ok <- validate_colour(colour),
         :ok <- validate_size(size),
         {:ok, variant} <- fetch_variant(product, colour, size) do
      size_surcharge =
        case String.upcase(size) do
          s when s in ~w(XL XXL) -> 5.0
          _ -> 0.0
        end

      colour_surcharge =
        case String.upcase(colour) do
          c when c in ~w(GOLD SILVER) -> 10.0
          _ -> 0.0
        end

      new_price = product.base_price + size_surcharge + colour_surcharge

      variant
      |> ProductVariant.changeset(%{price: new_price})
      |> Repo.update()
    end
  end

  @spec find_matching_variant(Product.t(), String.t(), String.t()) ::
          {:ok, ProductVariant.t()} | {:error, :not_found}
  def find_matching_variant(%Product{} = product, colour, size)
      when is_binary(colour) and is_binary(size) do
    fetch_variant(product, String.upcase(colour), String.upcase(size))
  end

  @spec build_variant_matrix(Product.t()) :: map()
  def build_variant_matrix(%Product{} = product) do
    variants =
      Repo.all(from v in ProductVariant, where: v.product_id == ^product.id and v.active == true)

    Enum.reduce(variants, %{}, fn v, acc ->
      colour_key = v.colour
      size_key = v.size
      row = Map.get(acc, colour_key, %{})
      updated_row = Map.put(row, size_key, %{sku: v.sku, price: v.price, in_stock: v.stock_quantity > 0})
      Map.put(acc, colour_key, updated_row)
    end)
  end


  ## Private helpers

  defp validate_colour(colour) when is_binary(colour) do
    if String.upcase(colour) in @valid_colours do
      :ok
    else
      {:error, {:invalid_colour, colour}}
    end
  end

  defp validate_size(size) when is_binary(size) do
    if String.upcase(size) in @valid_sizes do
      :ok
    else
      {:error, {:invalid_size, size}}
    end
  end

  defp variant_exists?(%Product{} = product, colour, size) do
    Repo.exists?(ProductVariant,
      product_id: product.id,
      colour: String.upcase(colour),
      size: String.upcase(size)
    )
  end

  defp fetch_variant(%Product{} = product, colour, size) do
    case Repo.get_by(ProductVariant,
           product_id: product.id,
           colour: String.upcase(colour),
           size: String.upcase(size)
         ) do
      nil -> {:error, :not_found}
      variant -> {:ok, variant}
    end
  end
end
```