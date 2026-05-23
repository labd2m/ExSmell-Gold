# Annotated Example — Primitive Obsession

## Metadata

- **Smell name:** Primitive Obsession
- **Expected smell location:** `Inventory.ProductCatalog` module — `weight_kg`, `length_cm`, `width_cm`, `height_cm` are four raw `float` primitives used throughout `register_product/6`, `calculate_volume/3`, `classify_shipping_tier/4`, and `validate_dimensions/4` instead of `Dimensions` and `Weight` structs
- **Affected functions:** `register_product/6`, `calculate_volume/3`, `classify_shipping_tier/4`, `validate_dimensions/4`
- **Short explanation:** Physical product dimensions (length, width, height) form a single cohesive domain concept. Representing them as three independent `float` parameters (plus a separate `float` for weight) inflates function arities to six or more, scatters dimensional constraints across multiple validators, and makes it easy to accidentally swap, e.g., `width_cm` and `height_cm` with no compile-time error. A `Dimensions` struct and a `Weight` struct would group and validate each concept in one place.

---

```elixir
defmodule Inventory.ProductCatalog do
  @moduledoc """
  Manages product registration and physical attribute classification
  for the warehouse inventory system.
  """

  require Logger
  alias Inventory.{Repo, Product, ShippingRules}

  @max_weight_kg 1_000.0
  @max_dimension_cm 500.0
  @max_volume_cm3 125_000_000.0

  @shipping_tiers %{
    "letter"   => {0.1, 30.0, 0.01},
    "parcel"   => {5.0, 120.0, 5_000.0},
    "freight"  => {70.0, 300.0, 500_000.0},
    "oversize" => {1_000.0, 500.0, 125_000_000.0}
  }

  # VALIDATION: SMELL START - Primitive Obsession
  # VALIDATION: This is a smell because the three physical dimensions of a product
  # (length, width, height) are a single cohesive domain value — they cannot be
  # meaningfully interpreted in isolation — yet they are dissolved into three
  # separate `float` parameters in every function. The same applies to `weight_kg`
  # being a plain float instead of a `Weight` type. This inflates `register_product`
  # to six positional arguments, forces validation logic to be spread across
  # multiple private functions, and makes argument-order mistakes invisible to the
  # compiler and type system.
  @spec register_product(String.t(), String.t(), float(), float(), float(), float()) ::
          {:ok, Product.t()} | {:error, String.t()}
  def register_product(sku, name, length_cm, width_cm, height_cm, weight_kg)
      when is_binary(sku) and is_binary(name) and
             is_float(length_cm) and is_float(width_cm) and
             is_float(height_cm) and is_float(weight_kg) do
    with :ok <- validate_sku(sku),
         :ok <- validate_dimensions(length_cm, width_cm, height_cm, weight_kg),
         shipping_tier = classify_shipping_tier(length_cm, width_cm, height_cm, weight_kg),
         volume_cm3 = calculate_volume(length_cm, width_cm, height_cm) do
      attrs = %{
        sku: String.upcase(sku),
        name: name,
        length_cm: length_cm,
        width_cm: width_cm,
        height_cm: height_cm,
        weight_kg: weight_kg,
        volume_cm3: volume_cm3,
        shipping_tier: shipping_tier,
        registered_at: DateTime.utc_now()
      }

      case Repo.insert(Product.changeset(%Product{}, attrs)) do
        {:ok, product} ->
          Logger.info("Product #{sku} registered — tier: #{shipping_tier}, vol: #{volume_cm3} cm³")
          {:ok, product}

        {:error, changeset} ->
          {:error, "product_registration_failed: #{inspect(changeset.errors)}"}
      end
    end
  end

  def register_product(_, _, _, _, _, _), do: {:error, "invalid_arguments"}

  @spec calculate_volume(float(), float(), float()) :: float()
  def calculate_volume(length_cm, width_cm, height_cm)
      when is_float(length_cm) and is_float(width_cm) and is_float(height_cm) do
    length_cm * width_cm * height_cm
  end

  @spec classify_shipping_tier(float(), float(), float(), float()) :: String.t()
  def classify_shipping_tier(length_cm, width_cm, height_cm, weight_kg) do
    volume = calculate_volume(length_cm, width_cm, height_cm)
    max_dim = Enum.max([length_cm, width_cm, height_cm])

    cond do
      weight_kg <= 0.1 and max_dim <= 30.0 and volume <= 0.01 -> "letter"
      weight_kg <= 5.0 and max_dim <= 120.0 and volume <= 5_000.0 -> "parcel"
      weight_kg <= 70.0 and max_dim <= 300.0 and volume <= 500_000.0 -> "freight"
      true -> "oversize"
    end
  end

  @spec validate_dimensions(float(), float(), float(), float()) ::
          :ok | {:error, String.t()}
  def validate_dimensions(length_cm, width_cm, height_cm, weight_kg) do
    volume = calculate_volume(length_cm, width_cm, height_cm)

    cond do
      length_cm <= 0.0 or width_cm <= 0.0 or height_cm <= 0.0 ->
        {:error, "dimensions_must_be_positive"}

      weight_kg <= 0.0 ->
        {:error, "weight_must_be_positive"}

      length_cm > @max_dimension_cm or width_cm > @max_dimension_cm or
          height_cm > @max_dimension_cm ->
        {:error, "dimension_exceeds_maximum_#{@max_dimension_cm}_cm"}

      weight_kg > @max_weight_kg ->
        {:error, "weight_exceeds_maximum_#{@max_weight_kg}_kg"}

      volume > @max_volume_cm3 ->
        {:error, "volume_exceeds_maximum"}

      true ->
        :ok
    end
  end
  # VALIDATION: SMELL END

  @spec lookup_product(String.t()) :: {:ok, Product.t()} | {:error, String.t()}
  def lookup_product(sku) when is_binary(sku) do
    case Repo.get_by(Product, sku: String.upcase(sku)) do
      nil -> {:error, "product_not_found"}
      product -> {:ok, product}
    end
  end

  @spec list_by_tier(String.t()) :: list(Product.t())
  def list_by_tier(tier) when is_binary(tier) do
    Repo.all(Product, shipping_tier: tier)
  end

  defp validate_sku(sku) do
    if Regex.match?(~r/^[A-Z0-9\-]{4,20}$/i, sku) do
      :ok
    else
      {:error, "invalid_sku_format"}
    end
  end
end
```
