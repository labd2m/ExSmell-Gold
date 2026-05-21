```elixir
defmodule DataPipeline.FieldCoercer do
  @moduledoc """
  Coerces field values from Elixir-native types into the legacy formats
  required by the downstream ERP and EDI integration layer.

  The target system expects all field values as either charlists (for most
  string fields) or integers (for numeric fields). This module bridges
  the type gap between the modern Elixir pipeline and the legacy connector.
  """

  @max_charlist_length 255
  @numeric_field_types [:quantity, :unit_price, :tax_code_id, :account_number]

  @doc """
  Coerces all fields in a row map to the types expected by the legacy connector.
  Returns `{:ok, coerced_map}` or `{:error, {field, reason}}`.
  """
  def coerce_row(row, schema) when is_map(row) and is_list(schema) do
    Enum.reduce_while(schema, {:ok, %{}}, fn {field, type}, {:ok, acc} ->
      value = Map.get(row, field)

      case coerce_field(value, type) do
        {:ok, coerced} -> {:cont, {:ok, Map.put(acc, field, coerced)}}
        {:error, reason} -> {:halt, {:error, {field, reason}}}
      end
    end)
  end

  @doc """
  Coerces a single field value to the specified legacy type.

  ## Parameters
    - `value`: The raw field value from the pipeline.
    - `type`: Either `:charlist` or `:integer`.
  """
  def coerce_field(nil, _type), do: {:ok, nil}
  def coerce_field(value, :integer) when is_integer(value), do: {:ok, value}

  def coerce_field(value, :integer) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> {:ok, int}
      _ -> {:error, :not_an_integer}
    end
  end

  def coerce_field(value, :charlist) do
    {:ok, coerce_to_charlist(value)}
  end

  def coerce_field(_, type), do: {:error, {:unsupported_type, type}}

  @doc """
  Converts a value to a charlist for the legacy string field format.
  Truncates to the maximum allowed charlist length.
  """
  def coerce_to_charlist(value) do
    value
    |> to_charlist()
    |> Enum.take(@max_charlist_length)
  end

  @doc """
  Returns the schema definition for a standard order row in the legacy EDI format.
  """
  def order_row_schema do
    [
      {:order_id, :charlist},
      {:customer_code, :charlist},
      {:item_code, :charlist},
      {:quantity, :integer},
      {:unit_price, :integer},
      {:currency, :charlist},
      {:delivery_date, :charlist},
      {:notes, :charlist}
    ]
  end

  @doc """
  Returns the schema for a standard inventory update row.
  """
  def inventory_row_schema do
    [
      {:sku, :charlist},
      {:warehouse_code, :charlist},
      {:quantity_on_hand, :integer},
      {:reorder_point, :integer},
      {:unit_of_measure, :charlist}
    ]
  end

  @doc """
  Determines whether a field type is numeric based on the schema conventions.
  """
  def numeric_field?(field_name) when is_atom(field_name) do
    field_name in @numeric_field_types
  end

  @doc """
  Counts how many fields in a row failed coercion, for pipeline monitoring.
  """
  def count_coercion_errors(row, schema) when is_map(row) and is_list(schema) do
    Enum.count(schema, fn {field, type} ->
      value = Map.get(row, field)

      case coerce_field(value, type) do
        {:ok, _} -> false
        {:error, _} -> true
      end
    end)
  end
end
```
