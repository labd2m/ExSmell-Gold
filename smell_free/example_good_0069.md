```elixir
defprotocol Serialization.Encodable do
  @moduledoc """
  Protocol for encoding domain structs into portable map representations
  suitable for JSON serialization or external API transport.
  """

  @spec encode(t()) :: map()
  def encode(value)
end

defprotocol Serialization.Decodable do
  @moduledoc """
  Protocol for reconstructing domain structs from raw decoded maps.

  Implementations should pattern-match on expected keys and return
  `{:ok, struct}` or `{:error, reason}` without raising.
  """

  @spec decode(t(), map()) :: {:ok, term()} | {:error, term()}
  def decode(schema_instance, raw_map)
end

defmodule Serialization do
  @moduledoc """
  Entry point for encoding and decoding domain entities using the
  `Encodable` and `Decodable` protocols.
  """

  @spec encode(term()) :: {:ok, String.t()} | {:error, :not_encodable}
  def encode(value) do
    if Serialization.Encodable.impl_for(value) do
      encoded = value |> Serialization.Encodable.encode() |> Jason.encode!()
      {:ok, encoded}
    else
      {:error, :not_encodable}
    end
  end

  @spec decode(module(), String.t()) :: {:ok, term()} | {:error, term()}
  def decode(schema, json) when is_atom(schema) and is_binary(json) do
    with {:ok, raw} <- Jason.decode(json),
         {:ok, result} <- Serialization.Decodable.decode(struct(schema), raw) do
      {:ok, result}
    end
  end
end

defmodule Catalog.Product do
  @moduledoc """
  Represents a product in the service catalog.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          sku: String.t(),
          name: String.t(),
          description: String.t() | nil,
          price_cents: non_neg_integer(),
          currency: String.t(),
          active: boolean()
        }

  defstruct [:id, :sku, :name, :description, :price_cents, :currency, active: true]
end

defimpl Serialization.Encodable, for: Catalog.Product do
  def encode(product) do
    %{
      "id" => product.id,
      "sku" => product.sku,
      "name" => product.name,
      "description" => product.description,
      "price_cents" => product.price_cents,
      "currency" => product.currency,
      "active" => product.active
    }
  end
end

defimpl Serialization.Decodable, for: Catalog.Product do
  def decode(
        _instance,
        %{
          "id" => id,
          "sku" => sku,
          "name" => name,
          "price_cents" => price_cents,
          "currency" => currency
        } = raw
      )
      when is_binary(id) and is_binary(sku) and is_binary(name) and
             is_integer(price_cents) and price_cents >= 0 and is_binary(currency) do
    product = %Catalog.Product{
      id: id,
      sku: sku,
      name: name,
      description: Map.get(raw, "description"),
      price_cents: price_cents,
      currency: currency,
      active: Map.get(raw, "active", true)
    }

    {:ok, product}
  end

  def decode(_instance, _invalid), do: {:error, :missing_required_fields}
end
```
