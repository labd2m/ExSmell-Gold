```elixir
defmodule Platform.SchemaReflection do
  @moduledoc """
  Pure-function utilities for inspecting Ecto schema metadata at runtime.

  Useful for building generic serializers, admin interfaces, form generators,
  and migration tooling that must operate on arbitrary schemas without
  hard-coding field names or types.
  """

  @type field_info :: %{
          name: atom(),
          type: term(),
          required: boolean(),
          default: term()
        }

  @type assoc_info :: %{
          name: atom(),
          kind: :belongs_to | :has_one | :has_many | :many_to_many,
          related: module(),
          foreign_key: atom()
        }

  @doc """
  Returns a list of field descriptors for the given schema module.
  Excludes virtual fields and Ecto internals like `:__meta__`.
  """
  @spec fields(module()) :: [field_info()]
  def fields(schema) when is_atom(schema) do
    schema.__schema__(:fields)
    |> Enum.reject(&(&1 == :__meta__))
    |> Enum.map(fn field ->
      %{
        name: field,
        type: schema.__schema__(:type, field),
        required: required?(schema, field),
        default: schema.__schema__(:default, field)
      }
    end)
  end

  @doc """
  Returns association descriptors for the given schema module.
  """
  @spec associations(module()) :: [assoc_info()]
  def associations(schema) when is_atom(schema) do
    schema.__schema__(:associations)
    |> Enum.map(fn assoc_name ->
      assoc = schema.__schema__(:association, assoc_name)
      %{
        name: assoc_name,
        kind: assoc_kind(assoc),
        related: Map.get(assoc, :related),
        foreign_key: Map.get(assoc, :owner_key) || Map.get(assoc, :foreign_key)
      }
    end)
  end

  @doc "Returns the primary key field(s) of the schema."
  @spec primary_keys(module()) :: [atom()]
  def primary_keys(schema) when is_atom(schema) do
    schema.__schema__(:primary_key)
  end

  @doc "Returns field names of a specific Ecto type (e.g., `:string`, `:integer`)."
  @spec fields_of_type(module(), term()) :: [atom()]
  def fields_of_type(schema, target_type) when is_atom(schema) do
    schema
    |> fields()
    |> Enum.filter(fn %{type: type} -> type == target_type end)
    |> Enum.map(& &1.name)
  end

  @doc """
  Builds a plain map from a struct, including only schema-declared fields.
  Strips Ecto-internal fields like `:__meta__` and unloaded associations.
  """
  @spec to_map(struct()) :: map()
  def to_map(%schema{} = record) do
    field_names = schema.__schema__(:fields)

    field_names
    |> Enum.reduce(%{}, fn field, acc ->
      value = Map.get(record, field)
      Map.put(acc, field, value)
    end)
  end

  @doc """
  Returns `true` if `field` is declared in the schema's `changeset/2` as required.
  Falls back to checking whether the field has a non-nil constraint in the DB.
  """
  @spec required?(module(), atom()) :: boolean()
  def required?(schema, field) when is_atom(schema) and is_atom(field) do
    case schema.__schema__(:type, field) do
      nil -> false
      _type ->
        schema.__schema__(:default, field) == nil and
          field not in optional_fields(schema)
    end
  end

  @doc "Returns all field names that embed another schema."
  @spec embedded_fields(module()) :: [atom()]
  def embedded_fields(schema) when is_atom(schema) do
    schema
    |> fields()
    |> Enum.filter(fn %{type: type} ->
      match?({:parameterized, Ecto.Embedded, _}, type)
    end)
    |> Enum.map(& &1.name)
  end

  @doc "Summarises the schema structure as a readable string for debugging."
  @spec describe(module()) :: String.t()
  def describe(schema) when is_atom(schema) do
    field_lines = fields(schema) |> Enum.map_join("\n", fn %{name: n, type: t} ->
      "  field :#{n}, #{inspect(t)}"
    end)

    "schema #{inspect(schema)} do\n#{field_lines}\nend"
  end

  defp assoc_kind(%Ecto.Association.BelongsTo{}), do: :belongs_to
  defp assoc_kind(%Ecto.Association.Has{cardinality: :one}), do: :has_one
  defp assoc_kind(%Ecto.Association.Has{cardinality: :many}), do: :has_many
  defp assoc_kind(%Ecto.Association.ManyToMany{}), do: :many_to_many
  defp assoc_kind(_), do: :unknown

  defp optional_fields(schema) do
    if function_exported?(schema, :__optional_fields__, 0) do
      schema.__optional_fields__()
    else
      [:inserted_at, :updated_at, :deleted_at, :id]
    end
  end
end
```
