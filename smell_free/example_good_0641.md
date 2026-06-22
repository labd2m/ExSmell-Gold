```elixir
defmodule Admin.QueryFilter do
  @moduledoc """
  A composable filter DSL for admin list endpoints. Filter parameters arrive
  as a flat string map from query strings. This module declares the allowed
  filter fields, their types, and the Ecto query transformation each field
  applies. Unknown fields are silently dropped so clients cannot probe for
  undeclared columns, and type coercion happens before any query is built.
  """

  import Ecto.Query

  @type filter_spec :: %{
          required(:field) => atom(),
          required(:type) => :string | :integer | :boolean | :date | :enum,
          optional(:enum_values) => [atom()],
          optional(:operator) => :eq | :ilike | :gte | :lte | :in
        }

  @doc """
  Applies a list of `filter_specs` to `queryable` using the raw filter params
  from the request. Returns a filtered query or `{:error, [binary()]}` when
  coercion fails for any provided param.
  """
  @spec apply(Ecto.Queryable.t(), map(), [filter_spec()]) ::
          {:ok, Ecto.Query.t()} | {:error, [binary()]}
  def apply(queryable, raw_params, specs) when is_map(raw_params) and is_list(specs) do
    specs_by_key = Map.new(specs, &{to_string(&1.field), &1})

    {coerced, errors} =
      raw_params
      |> Map.take(Map.keys(specs_by_key))
      |> Enum.reduce({%{}, []}, fn {key, raw_value}, {ok_acc, err_acc} ->
        spec = Map.fetch!(specs_by_key, key)

        case coerce(raw_value, spec.type, Map.get(spec, :enum_values)) do
          {:ok, value} -> {Map.put(ok_acc, spec.field, value), err_acc}
          {:error, msg} -> {ok_acc, ["#{key}: #{msg}" | err_acc]}
        end
      end)

    if errors == [] do
      query =
        Enum.reduce(coerced, queryable, fn {field, value}, q ->
          spec = Enum.find(specs, &(&1.field == field))
          apply_filter(q, field, value, Map.get(spec, :operator, :eq))
        end)

      {:ok, query}
    else
      {:error, Enum.reverse(errors)}
    end
  end

  # ---------------------------------------------------------------------------
  # Coercion
  # ---------------------------------------------------------------------------

  defp coerce(raw, :string, _enums) when is_binary(raw), do: {:ok, raw}
  defp coerce(raw, :string, _enums), do: {:ok, to_string(raw)}

  defp coerce(raw, :integer, _enums) when is_binary(raw) do
    case Integer.parse(raw) do
      {n, ""} -> {:ok, n}
      _ -> {:error, "must be an integer"}
    end
  end

  defp coerce(raw, :integer, _enums) when is_integer(raw), do: {:ok, raw}
  defp coerce(_raw, :integer, _enums), do: {:error, "must be an integer"}

  defp coerce("true", :boolean, _enums), do: {:ok, true}
  defp coerce("false", :boolean, _enums), do: {:ok, false}
  defp coerce(raw, :boolean, _enums) when is_boolean(raw), do: {:ok, raw}
  defp coerce(_raw, :boolean, _enums), do: {:error, "must be true or false"}

  defp coerce(raw, :date, _enums) when is_binary(raw) do
    case Date.from_iso8601(raw) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, "must be an ISO 8601 date (YYYY-MM-DD)"}
    end
  end

  defp coerce(raw, :enum, enum_values) when is_binary(raw) do
    atom = String.to_existing_atom(raw)
    if atom in enum_values, do: {:ok, atom}, else: {:error, "must be one of #{inspect(enum_values)}"}
  rescue
    ArgumentError -> {:error, "must be one of #{inspect(enum_values)}"}
  end

  defp coerce(_raw, type, _enums), do: {:error, "unsupported type #{type}"}

  # ---------------------------------------------------------------------------
  # Query operators
  # ---------------------------------------------------------------------------

  defp apply_filter(query, field, value, :eq) do
    where(query, [r], field(r, ^field) == ^value)
  end

  defp apply_filter(query, field, value, :ilike) do
    term = "%#{value}%"
    where(query, [r], ilike(field(r, ^field), ^term))
  end

  defp apply_filter(query, field, value, :gte) do
    where(query, [r], field(r, ^field) >= ^value)
  end

  defp apply_filter(query, field, value, :lte) do
    where(query, [r], field(r, ^field) <= ^value)
  end

  defp apply_filter(query, field, value, :in) when is_list(value) do
    where(query, [r], field(r, ^field) in ^value)
  end
end
```
