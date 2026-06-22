```elixir
defprotocol Catalog.Encodable do
  @moduledoc """
  Protocol for serializing catalog domain entities to a wire-format map.
  Implement this protocol for any struct that must be sent over an API boundary.
  """

  @spec encode(t()) :: {:ok, map()} | {:error, String.t()}
  def encode(value)
end

defmodule Catalog.Product do
  @moduledoc """
  Represents a sellable product in the catalog.
  """

  @enforce_keys [:id, :sku, :name, :price_cents]
  defstruct [:id, :sku, :name, :price_cents, :description, :active]

  @type t :: %__MODULE__{
          id: integer(),
          sku: String.t(),
          name: String.t(),
          price_cents: non_neg_integer(),
          description: String.t() | nil,
          active: boolean() | nil
        }
end

defimpl Catalog.Encodable, for: Catalog.Product do
  def encode(%Catalog.Product{} = p) do
    {:ok,
     %{
       "id" => p.id,
       "sku" => p.sku,
       "name" => p.name,
       "price_cents" => p.price_cents,
       "description" => p.description,
       "active" => p.active || false
     }}
  end
end

defmodule Catalog.Category do
  @moduledoc """
  Represents a browseable product category.
  """

  @enforce_keys [:id, :slug, :label]
  defstruct [:id, :slug, :label, :parent_id]

  @type t :: %__MODULE__{
          id: integer(),
          slug: String.t(),
          label: String.t(),
          parent_id: integer() | nil
        }
end

defimpl Catalog.Encodable, for: Catalog.Category do
  def encode(%Catalog.Category{} = c) do
    {:ok,
     %{
       "id" => c.id,
       "slug" => c.slug,
       "label" => c.label,
       "parent_id" => c.parent_id
     }}
  end
end

defmodule Catalog.Encoder do
  @moduledoc """
  Batch-encodes a list of catalog entities, separating successes from failures.
  """

  @type batch_result :: %{encoded: list(map()), errors: list(String.t())}

  @spec encode_all(list()) :: batch_result()
  def encode_all(values) when is_list(values) do
    values
    |> Enum.reduce(%{encoded: [], errors: []}, &reduce_encoded/2)
    |> Map.update!(:encoded, &Enum.reverse/1)
    |> Map.update!(:errors, &Enum.reverse/1)
  end

  @spec encode_one(term()) :: {:ok, map()} | {:error, String.t()}
  def encode_one(value) do
    Catalog.Encodable.encode(value)
  rescue
    Protocol.UndefinedError -> {:error, "no encoder for #{inspect(value.__struct__)}"}
  end

  defp reduce_encoded(value, acc) do
    case Catalog.Encodable.encode(value) do
      {:ok, encoded} -> Map.update!(acc, :encoded, &[encoded | &1])
      {:error, reason} -> Map.update!(acc, :errors, &[reason | &1])
    end
  end
end
```
