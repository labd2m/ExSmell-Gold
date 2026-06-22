```elixir
defmodule Sql.Token do
  @moduledoc false

  @type kind ::
          :keyword
          | :identifier
          | :string_literal
          | :integer_literal
          | :float_literal
          | :operator
          | :punctuation
          | :placeholder
          | :whitespace

  @type t :: %__MODULE__{kind: kind(), value: String.t(), position: non_neg_integer()}

  defstruct [:kind, :value, :position]
end

defmodule Sql.Lexer do
  @moduledoc """
  Tokenizes a SQL string into a typed stream of `Sql.Token` structs.

  The lexer operates as a single left-to-right pass using pattern matching
  on the remaining input. Whitespace tokens are optionally included for
  source-mapping purposes; downstream parsers typically filter them out.
  Unrecognised characters are emitted as single-character `:identifier`
  tokens so the stream is always complete rather than raising on unknown input.
  """

  alias Sql.Token

  @keywords ~w(
    SELECT FROM WHERE JOIN INNER OUTER LEFT RIGHT FULL CROSS
    ON AS INSERT INTO UPDATE SET DELETE CREATE DROP TABLE INDEX
    ALTER ADD COLUMN PRIMARY KEY FOREIGN REFERENCES UNIQUE NOT NULL
    DEFAULT AND OR IN LIKE BETWEEN IS DISTINCT GROUP BY ORDER
    HAVING LIMIT OFFSET UNION ALL CASE WHEN THEN ELSE END
    WITH RECURSIVE EXISTS COUNT SUM AVG MIN MAX COALESCE
  )a

  @keyword_set MapSet.new(Enum.map(@keywords, &Atom.to_string/1))

  @spec tokenize(String.t()) :: [Token.t()]
  def tokenize(sql) when is_binary(sql) do
    do_tokenize(sql, 0, []) |> Enum.reverse()
  end

  @spec tokenize_significant(String.t()) :: [Token.t()]
  def tokenize_significant(sql) do
    sql |> tokenize() |> Enum.reject(&(&1.kind == :whitespace))
  end

  defp do_tokenize("", _pos, acc), do: acc

  defp do_tokenize(<<ch, _::binary>> = input, pos, acc) when ch in [?\s, ?\t, ?\r, ?\n] do
    {ws, rest} = consume_while(input, &(&1 in [?\s, ?\t, ?\r, ?\n]))
    tok = %Token{kind: :whitespace, value: ws, position: pos}
    do_tokenize(rest, pos + String.length(ws), [tok | acc])
  end

  defp do_tokenize(<<"'", rest::binary>>, pos, acc) do
    {content, remaining} = consume_string_literal(rest, "'")
    tok = %Token{kind: :string_literal, value: "'#{content}'", position: pos}
    do_tokenize(remaining, pos + String.length(tok.value), [tok | acc])
  end

  defp do_tokenize(<<"\"", rest::binary>>, pos, acc) do
    {content, remaining} = consume_string_literal(rest, "\"")
    tok = %Token{kind: :identifier, value: ~s("#{content}"), position: pos}
    do_tokenize(remaining, pos + String.length(tok.value), [tok | acc])
  end

  defp do_tokenize(<<"$", rest::binary>>, pos, acc) do
    {digits, remaining} = consume_while(rest, &(&1 in ?0..?9))
    tok = %Token{kind: :placeholder, value: "$#{digits}", position: pos}
    do_tokenize(remaining, pos + String.length(tok.value), [tok | acc])
  end

  defp do_tokenize(<<ch, _::binary>> = input, pos, acc) when ch in ?0..?9 do
    {number, rest} = consume_number(input)
    kind = if String.contains?(number, "."), do: :float_literal, else: :integer_literal
    tok = %Token{kind: kind, value: number, position: pos}
    do_tokenize(rest, pos + String.length(number), [tok | acc])
  end

  defp do_tokenize(<<ch, _::binary>> = input, pos, acc)
       when ch in ?a..?z or ch in ?A..?Z or ch == ?_ do
    {word, rest} = consume_while(input, &(&1 in ?a..?z or &1 in ?A..?Z or &1 in ?0..?9 or &1 == ?_))
    kind = if MapSet.member?(@keyword_set, String.upcase(word)), do: :keyword, else: :identifier
    tok = %Token{kind: kind, value: word, position: pos}
    do_tokenize(rest, pos + String.length(word), [tok | acc])
  end

  defp do_tokenize(<<op, _::binary>> = input, pos, acc) when op in [?=, ?<, ?>, ?!, ?+, ?-, ?*, ?/, ?|, ?&] do
    {symbol, rest} = consume_while(input, &(&1 in [?=, ?<, ?>, ?!, ?+, ?-, ?*, ?/, ?|, ?&]))
    tok = %Token{kind: :operator, value: symbol, position: pos}
    do_tokenize(rest, pos + String.length(symbol), [tok | acc])
  end

  defp do_tokenize(<<ch, rest::binary>>, pos, acc) do
    kind = if ch in [?(, ?), ?,, ?;, ?., ?[] , do: :punctuation, else: :identifier
    tok = %Token{kind: kind, value: <<ch>>, position: pos}
    do_tokenize(rest, pos + 1, [tok | acc])
  end

  defp consume_while(str, pred) do
    {chars, rest} = str |> String.to_charlist() |> Enum.split_while(pred)
    {List.to_string(chars), List.to_string(rest)}
  end

  defp consume_string_literal(str, delimiter) do
    case String.split(str, delimiter, parts: 2) do
      [content, rest] -> {content, rest}
      [content] -> {content, ""}
    end
  end

  defp consume_number(str) do
    {digits, rest} = consume_while(str, &(&1 in ?0..?9))

    if String.starts_with?(rest, ".") do
      {decimals, final} = consume_while(String.slice(rest, 1..-1//1), &(&1 in ?0..?9))
      {"#{digits}.#{decimals}", final}
    else
      {digits, rest}
    end
  end
end
```
