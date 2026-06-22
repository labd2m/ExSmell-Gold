# File: `example_good_618.md`

```elixir
defmodule Search.BooleanQueryParser do
  @moduledoc """
  Parses a boolean search query string into a structured AST that can
  be translated to SQL, Elasticsearch DSL, or evaluated in-memory.

  Supports AND, OR, NOT operators, phrase matching with double quotes,
  field-scoped terms (field:value), and nested groups with parentheses.

  Operator precedence: NOT > AND > OR.
  """

  @type term_node :: {:term, String.t()}
  @type phrase_node :: {:phrase, String.t()}
  @type field_node :: {:field, String.t(), String.t()}
  @type and_node :: {:and, node(), node()}
  @type or_node :: {:or, node(), node()}
  @type not_node :: {:not, node()}
  @type node :: term_node() | phrase_node() | field_node() | and_node() | or_node() | not_node()

  @type parse_result :: {:ok, node()} | {:error, String.t()}

  @doc """
  Parses a boolean query string into an AST node.

  Operators must be uppercase (AND, OR, NOT). Terms are case-sensitive.
  Phrases are enclosed in double quotes. Field-scoped terms use the
  `field:value` syntax.

  Returns `{:ok, ast}` or `{:error, message}`.
  """
  @spec parse(String.t()) :: parse_result()
  def parse(query) when is_binary(query) do
    tokens = tokenize(query)

    case parse_or(tokens) do
      {ast, []} -> {:ok, ast}
      {_ast, remaining} -> {:error, "unexpected tokens: #{inspect(remaining)}"}
      {:error, _} = error -> error
    end
  rescue
    e -> {:error, "parse error: #{Exception.message(e)}"}
  end

  @doc """
  Evaluates an AST against a document map, returning `true` when the
  document satisfies the query.

  Each field is matched against the corresponding document key.
  Unscoped terms match any string value in the document.
  """
  @spec evaluate(node(), map()) :: boolean()
  def evaluate({:term, term}, doc) do
    doc |> Map.values() |> Enum.any?(&(is_binary(&1) and String.contains?(String.downcase(&1), String.downcase(term))))
  end

  def evaluate({:phrase, phrase}, doc) do
    doc |> Map.values() |> Enum.any?(&(is_binary(&1) and String.contains?(String.downcase(&1), String.downcase(phrase))))
  end

  def evaluate({:field, field, value}, doc) do
    doc_value = Map.get(doc, field) || Map.get(doc, String.to_existing_atom(field))
    is_binary(doc_value) and String.contains?(String.downcase(doc_value), String.downcase(value))
  rescue
    ArgumentError -> false
  end

  def evaluate({:and, left, right}, doc) do
    evaluate(left, doc) and evaluate(right, doc)
  end

  def evaluate({:or, left, right}, doc) do
    evaluate(left, doc) or evaluate(right, doc)
  end

  def evaluate({:not, operand}, doc) do
    not evaluate(operand, doc)
  end

  defp parse_or(tokens) do
    {left, rest} = parse_and(tokens)

    case rest do
      ["OR" | tail] ->
        {right, remaining} = parse_or(tail)
        {{:or, left, right}, remaining}

      _ ->
        {left, rest}
    end
  end

  defp parse_and(tokens) do
    {left, rest} = parse_not(tokens)

    case rest do
      ["AND" | tail] ->
        {right, remaining} = parse_and(tail)
        {{:and, left, right}, remaining}

      _ ->
        {left, rest}
    end
  end

  defp parse_not(["NOT" | rest]) do
    {operand, remaining} = parse_primary(rest)
    {{:not, operand}, remaining}
  end

  defp parse_not(tokens), do: parse_primary(tokens)

  defp parse_primary(["(" | rest]) do
    {inner, remaining} = parse_or(rest)

    case remaining do
      [")" | tail] -> {inner, tail}
      _ -> raise "missing closing parenthesis"
    end
  end

  defp parse_primary([{:phrase, phrase} | rest]), do: {{:phrase, phrase}, rest}

  defp parse_primary([term | rest]) when is_binary(term) do
    case String.split(term, ":", parts: 2) do
      [field, value] when field != "" and value != "" ->
        {{:field, field, value}, rest}

      _ ->
        {{:term, term}, rest}
    end
  end

  defp parse_primary([]), do: raise("unexpected end of query")

  defp tokenize(query) do
    ~r/"[^"]*"|\(|\)|AND|OR|NOT|[^\s()]+/
    |> Regex.scan(query)
    |> List.flatten()
    |> Enum.map(fn token ->
      if String.starts_with?(token, "\"") and String.ends_with?(token, "\"") do
        {:phrase, String.slice(token, 1, String.length(token) - 2)}
      else
        token
      end
    end)
  end
end
```
