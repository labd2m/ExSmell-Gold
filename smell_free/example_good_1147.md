```elixir
defprotocol Catalog.Encodable do
  @moduledoc """
  Protocol for converting catalog domain structs into wire-safe string-keyed
  maps suitable for JSON serialization and inter-service transport.

  Implementations must return a plain map with binary string keys and only
  JSON-serializable leaf values.
  """

  @doc "Encodes the value into a string-keyed plain map."
  @spec encode(t()) :: map()
  def encode(value)
end

defmodule Catalog.Product do
  @moduledoc "Represents a sellable product entry in the catalog."

  @enforce_keys [:id, :sku, :name, :price_cents, :currency]
  defstruct [:id, :sku, :name, :price_cents, :currency, :description, active: true]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          sku: String.t(),
          name: String.t(),
          price_cents: non_neg_integer(),
          currency: String.t(),
          description: String.t() | nil,
          active: boolean()
        }

  defimpl Catalog.Encodable do
    @doc false
    def encode(%Catalog.Product{} = product) do
      %{
        "id" => product.id,
        "sku" => product.sku,
        "name" => product.name,
        "price_cents" => product.price_cents,
        "currency" => product.currency,
        "description" => product.description,
        "active" => product.active
      }
    end
  end
end

defmodule Catalog.Category do
  @moduledoc "Represents a hierarchical product category node."

  @enforce_keys [:id, :slug, :label]
  defstruct [:id, :slug, :label, :parent_id]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          slug: String.t(),
          label: String.t(),
          parent_id: Ecto.UUID.t() | nil
        }

  defimpl Catalog.Encodable do
    @doc false
    def encode(%Catalog.Category{} = category) do
      %{
        "id" => category.id,
        "slug" => category.slug,
        "label" => category.label,
        "parent_id" => category.parent_id
      }
    end
  end
end

defmodule Catalog.Encoder do
  @moduledoc """
  Utility functions for batch-encoding and JSON-serializing catalog entities
  that implement the `Catalog.Encodable` protocol.
  """

  alias Catalog.Encodable

  @doc "Encodes a list of encodable structs into a list of plain string-keyed maps."
  @spec encode_all([Encodable.t()]) :: [map()]
  def encode_all(items) when is_list(items) do
    Enum.map(items, &Encodable.encode/1)
  end

  @doc "Serializes a single encodable struct to a JSON binary."
  @spec to_json(Encodable.t()) :: {:ok, binary()} | {:error, Jason.EncodeError.t()}
  def to_json(value) do
    value
    |> Encodable.encode()
    |> Jason.encode()
  end

  @doc "Serializes a list of encodable structs to a JSON array binary."
  @spec list_to_json([Encodable.t()]) :: {:ok, binary()} | {:error, Jason.EncodeError.t()}
  def list_to_json(items) when is_list(items) do
    items
    |> encode_all()
    |> Jason.encode()
  end

  @doc """
  Serializes a single encodable struct and raises on encoding failure.

  Use this variant only when encoding is expected to always succeed, such as
  when the struct contents have already been validated upstream.
  """
  @spec to_json!(Encodable.t()) :: binary()
  def to_json!(value) do
    value
    |> Encodable.encode()
    |> Jason.encode!()
  end
end
```
