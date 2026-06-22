```elixir
defmodule Platform.Search.QueryParser do
  @moduledoc """
  Parses structured search query strings into a typed query AST.
  Supports field qualifiers, phrase matching, boolean operators, and range filters.
  The parser produces an explicit error on malformed input rather than silently degrading.
  """

  @type field :: String.t()
  @type term_node :: {:term, String.t()}
  @type phrase_node :: {:phrase, String.t()}
  @type field_node :: {:field, field(), query_node()}
  @type range_node :: {:range, field(), number() | nil, number() | nil}
  @type bool_node :: {:and, query_node(), query_node()} | {:or, query_node(), query_node()}
  @type not_node :: {:not, query_node()}
  @type query_node ::
          term_node() | phrase_node() | field_node() | range_node() | bool_node() | not_node()

  @type parse_result :: {:ok, query_node()} | {:error, String.t()}

  @doc """
  Parses a query string into an AST node.

  Supported syntax:
    - `word` - term match
    - `"phrase words"` - exact phrase
    - `field:value` - field qualifier
    - `field:[min TO max]` - range filter (use `*` for open bound)
    - `a AND b`, `a OR b`, `NOT a` - boolean operators
  """
  @spec parse(String.t()) :: parse_result()
  def parse(input) when is_binary(input) do
    trimmed = String.trim(input)

    if trimmed == "" do
      {:error, "query must not be empty"}
    else
      do_parse(trimmed)
    end
  end

  defp do_parse(input) do
    cond do
      String.contains?(input, " AND ") -> parse_binary_op(input, " AND ", :and)
      String.contains?(input, " OR ") -> parse_binary_op(input, " OR ", :or)
      String.starts_with?(input, "NOT ") -> parse_not(input)
      String.starts_with?(input, "\"") -> parse_phrase(input)
      range_field?(input) -> parse_range(input)
      field_qualified?(input) -> parse_field_qualifier(input)
      true -> parse_term(input)
    end
  end

  defp parse_binary_op(input, separator, op) do
    case String.split(input, separator, parts: 2) do
      [left, right] ->
        with {:ok, left_node} <- do_parse(String.trim(left)),
             {:ok, right_node} <- do_parse(String.trim(right)) do
          {:ok, {op, left_node, right_node}}
        end

      _ ->
        {:error, "malformed #{op} expression: #{inspect(input)}"}
    end
  end

  defp parse_not("NOT " <> rest) do
    case do_parse(String.trim(rest)) do
      {:ok, node} -> {:ok, {:not, node}}
      {:error, _} = err -> err
    end
  end

  defp parse_phrase(input) do
    case Regex.run(~r/^"([^"]+)"$/, input) do
      [_, phrase] -> {:ok, {:phrase, phrase}}
      nil -> {:error, "malformed phrase, expected quoted string: #{inspect(input)}"}
    end
  end

  defp parse_range(input) do
    case Regex.run(~r/^(\w+):\[(.+) TO (.+)\]$/, input) do
      [_, field, low_str, high_str] ->
        with {:ok, low} <- parse_bound(low_str),
             {:ok, high} <- parse_bound(high_str) do
          {:ok, {:range, field, low, high}}
        end

      nil ->
        {:error, "malformed range filter: #{inspect(input)}"}
    end
  end

  defp parse_field_qualifier(input) do
    case String.split(input, ":", parts: 2) do
      [field, value] when field != "" and value != "" ->
        case do_parse(value) do
          {:ok, node} -> {:ok, {:field, field, node}}
          {:error, _} = err -> err
        end

      _ ->
        {:error, "malformed field qualifier: #{inspect(input)}"}
    end
  end

  defp parse_term(input) do
    if Regex.match?(~r/^\S+$/, input) do
      {:ok, {:term, input}}
    else
      {:error, "term must not contain whitespace: #{inspect(input)}"}
    end
  end

  defp parse_bound("*"), do: {:ok, nil}

  defp parse_bound(str) do
    case Float.parse(str) do
      {num, ""} -> {:ok, num}
      _ ->
        case Integer.parse(str) do
          {num, ""} -> {:ok, num * 1.0}
          _ -> {:error, "invalid range bound: #{inspect(str)}"}
        end
    end
  end

  defp range_field?(input), do: Regex.match?(~r/^\w+:\[.+ TO .+\]$/, input)
  defp field_qualified?(input), do: Regex.match?(~r/^\w+:[^\s]/, input)
end
```
