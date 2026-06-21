```elixir
defmodule Search.Filter do
  @moduledoc """
  A single typed filter condition extracted from a search query string.
  """

  @type operator :: :eq | :gt | :gte | :lt | :lte | :contains | :prefix

  @type t :: %__MODULE__{
          field: String.t(),
          operator: operator(),
          value: String.t()
        }

  defstruct [:field, :operator, :value]
end

defmodule Search.ParsedQuery do
  @moduledoc false

  @type t :: %__MODULE__{
          terms: [String.t()],
          filters: [Search.Filter.t()],
          raw: String.t()
        }

  defstruct [:raw, terms: [], filters: []]
end

defmodule Search.QueryParser do
  @moduledoc """
  Parses a free-text search string into a typed `ParsedQuery`.

  Tokens of the form `field:value`, `field>value`, or `field>=value`
  are extracted as structured `Filter` structs. Remaining bare words
  are collected as full-text search terms. Unknown operators are treated
  as bare terms rather than raising, keeping the parser lenient for
  end-user input.
  """

  alias Search.{Filter, ParsedQuery}

  @operator_patterns [
    {~r/^(\w+):(.+)$/, :eq},
    {~r/^(\w+)>=(.+)$/, :gte},
    {~r/^(\w+)>(.+)$/, :gt},
    {~r/^(\w+)<=(.+)$/, :lte},
    {~r/^(\w+)<(.+)$/, :lt},
    {~r/^(\w+)~(.+)$/, :contains},
    {~r/^(\w+)\^(.+)$/, :prefix}
  ]

  @spec parse(String.t()) :: ParsedQuery.t()
  def parse(input) when is_binary(input) do
    tokens = tokenize(input)
    {filters, terms} = Enum.reduce(tokens, {[], []}, &classify_token/2)

    %ParsedQuery{
      raw: input,
      filters: Enum.reverse(filters),
      terms: terms |> Enum.reverse() |> Enum.reject(&(&1 == ""))
    }
  end

  defp tokenize(input) do
    input
    |> String.trim()
    |> String.split(~r/\s+/)
  end

  defp classify_token(token, {filters, terms}) do
    case try_parse_filter(token) do
      {:ok, filter} -> {[filter | filters], terms}
      :not_a_filter -> {filters, [token | terms]}
    end
  end

  defp try_parse_filter(token) do
    Enum.find_value(@operator_patterns, :not_a_filter, fn {pattern, operator} ->
      case Regex.run(pattern, token) do
        [_full, field, value] ->
          {:ok, %Filter{field: field, operator: operator, value: value}}

        nil ->
          nil
      end
    end)
  end
end

defmodule Search.EctoAdapter do
  @moduledoc """
  Translates a `ParsedQuery` into an Ecto query fragment.

  Only filters whose field names appear in the declared `allowed_fields`
  list are applied; unknown fields are silently skipped to prevent
  arbitrary column probing.
  """

  import Ecto.Query

  alias Search.{Filter, ParsedQuery}

  @spec apply(Ecto.Queryable.t(), ParsedQuery.t(), [atom()]) :: Ecto.Query.t()
  def apply(queryable, %ParsedQuery{filters: filters}, allowed_fields)
      when is_list(allowed_fields) do
    Enum.reduce(filters, queryable, fn filter, query ->
      apply_filter(query, filter, allowed_fields)
    end)
  end

  defp apply_filter(query, %Filter{field: field_str, operator: op, value: value}, allowed) do
    case Enum.find(allowed, &(Atom.to_string(&1) == field_str)) do
      nil -> query
      field -> build_condition(query, field, op, value)
    end
  end

  defp build_condition(query, field, :eq, value) do
    from r in query, where: field(r, ^field) == ^value
  end

  defp build_condition(query, field, :gt, value) do
    from r in query, where: field(r, ^field) > ^value
  end

  defp build_condition(query, field, :gte, value) do
    from r in query, where: field(r, ^field) >= ^value
  end

  defp build_condition(query, field, :lt, value) do
    from r in query, where: field(r, ^field) < ^value
  end

  defp build_condition(query, field, :lte, value) do
    from r in query, where: field(r, ^field) <= ^value
  end

  defp build_condition(query, field, :contains, value) do
    from r in query, where: ilike(field(r, ^field), ^"%#{value}%")
  end

  defp build_condition(query, field, :prefix, value) do
    from r in query, where: ilike(field(r, ^field), ^"#{value}%")
  end
end
```
