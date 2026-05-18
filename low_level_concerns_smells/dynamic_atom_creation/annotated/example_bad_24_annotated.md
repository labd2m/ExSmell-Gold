# Annotated Example — Dynamic Atom Creation

| Field | Value |
|---|---|
| **Smell name** | Dynamic atom creation |
| **Expected smell location** | `SearchFilterBuilder.build_filters/1`, line where `String.to_atom/1` converts filter field name strings |
| **Affected function(s)** | `SearchFilterBuilder.build_filters/1` |
| **Short explanation** | Filter field names are extracted from a JSON query body sent by API clients and converted to atoms to be used as keys when constructing Ecto query expressions. Clients can send any field name they choose; each novel field name permanently occupies a slot in BEAM's atom table, and a public-facing search API receives this code on every search request. |

```elixir
defmodule MyApp.Search.SearchFilterBuilder do
  @moduledoc """
  Builds Ecto-compatible filter expressions from structured JSON search
  queries sent by API clients. Supports nested boolean logic, range filters,
  term matching, and full-text search across the product catalogue.
  """

  require Logger

  import Ecto.Query

  alias MyApp.Catalogue.Product

  @allowed_fields ~w(
    name category brand status price_cents stock_count
    created_at updated_at weight_grams country_of_origin
  )

  @allowed_operators ~w(eq neq gt gte lt lte in nin contains starts_with)

  @doc """
  Accepts a parsed JSON filter tree and returns an `Ecto.Query` with
  all applicable `where` clauses applied.
  """
  @spec apply(Ecto.Query.t(), map()) :: {:ok, Ecto.Query.t()} | {:error, term()}
  def apply(base_query, %{"filters" => filters}) when is_list(filters) do
    case build_filters(filters) do
      {:ok, clauses} ->
        query = Enum.reduce(clauses, base_query, fn clause, q -> where(q, ^clause) end)
        {:ok, query}

      {:error, _} = err ->
        err
    end
  end

  def apply(base_query, _params), do: {:ok, base_query}

  @doc """
  Validates and constructs sorting options from request params.
  """
  @spec build_sort(map()) :: {:ok, keyword()} | {:error, term()}
  def build_sort(%{"sort_by" => field, "sort_dir" => dir}) do
    with true <- field in @allowed_fields,
         true <- dir in ["asc", "desc"] do
      {:ok, [{String.to_existing_atom(dir), String.to_existing_atom(field)}]}
    else
      false -> {:error, :invalid_sort_params}
    end
  end

  def build_sort(_), do: {:ok, [asc: :inserted_at]}

  # VALIDATION: SMELL START - Dynamic atom creation
  # VALIDATION: This is a smell because `String.to_atom/1` is applied to the
  # `"field"` key from each filter object in the client-supplied JSON request body.
  # Even though the function checks `field in @allowed_fields` before using the
  # atom in a query clause, the atom is created unconditionally before that guard
  # runs. Any API client sending a novel field name—whether a legitimate future
  # field, a typo, or a fuzzing attempt—permanently allocates a new atom on every
  # such request. Because search is typically a high-traffic endpoint, this
  # accumulation can be significant.
  defp build_filters(filters) when is_list(filters) do
    Enum.reduce_while(filters, {:ok, []}, fn filter, {:ok, acc} ->
      case build_single_filter(filter) do
        {:ok, clause} -> {:cont, {:ok, [clause | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, clauses} -> {:ok, Enum.reverse(clauses)}
      err -> err
    end
  end

  defp build_single_filter(%{"field" => field, "op" => op, "value" => value}) do
    field_atom = String.to_atom(field)

    with true <- field in @allowed_fields or {:error, {:unknown_field, field}},
         true <- op in @allowed_operators or {:error, {:unknown_operator, op}} do
      build_clause(field_atom, op, value)
    end
  end
  # VALIDATION: SMELL END

  defp build_single_filter(_), do: {:error, :malformed_filter}

  defp build_clause(field, "eq", value), do: {:ok, dynamic([p], field(p, ^field) == ^value)}
  defp build_clause(field, "neq", value), do: {:ok, dynamic([p], field(p, ^field) != ^value)}
  defp build_clause(field, "gt", value), do: {:ok, dynamic([p], field(p, ^field) > ^value)}
  defp build_clause(field, "gte", value), do: {:ok, dynamic([p], field(p, ^field) >= ^value)}
  defp build_clause(field, "lt", value), do: {:ok, dynamic([p], field(p, ^field) < ^value)}
  defp build_clause(field, "lte", value), do: {:ok, dynamic([p], field(p, ^field) <= ^value)}
  defp build_clause(field, "in", value) when is_list(value), do: {:ok, dynamic([p], field(p, ^field) in ^value)}
  defp build_clause(field, "nin", value) when is_list(value), do: {:ok, dynamic([p], field(p, ^field) not in ^value)}

  defp build_clause(field, "contains", value) when is_binary(value) do
    pattern = "%#{value}%"
    {:ok, dynamic([p], ilike(field(p, ^field), ^pattern))}
  end

  defp build_clause(field, "starts_with", value) when is_binary(value) do
    pattern = "#{value}%"
    {:ok, dynamic([p], ilike(field(p, ^field), ^pattern))}
  end

  defp build_clause(_field, op, _value), do: {:error, {:unsupported_operator_value_combo, op}}
end
```
