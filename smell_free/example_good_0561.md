```elixir
defmodule Template.Token do
  @moduledoc false

  @type kind :: :literal | :variable | :section_open | :section_close | :inverted_open

  @type t :: %__MODULE__{kind: kind(), value: String.t()}

  defstruct [:kind, :value]
end

defmodule Template.Lexer do
  @moduledoc false

  alias Template.Token

  @spec tokenize(String.t()) :: [Token.t()]
  def tokenize(source) when is_binary(source) do
    ~r/(\{\{[#^\/]?[^}]+\}\})/
    |> Regex.split(source, include_captures: true, trim: true)
    |> Enum.map(&classify/1)
  end

  defp classify("{{#" <> rest), do: %Token{kind: :section_open, value: trim_close(rest)}
  defp classify("{{^" <> rest), do: %Token{kind: :inverted_open, value: trim_close(rest)}
  defp classify("{{/" <> rest), do: %Token{kind: :section_close, value: trim_close(rest)}
  defp classify("{{" <> rest), do: %Token{kind: :variable, value: trim_close(rest)}
  defp classify(text), do: %Token{kind: :literal, value: text}

  defp trim_close(str), do: str |> String.replace_suffix("}}", "") |> String.trim()
end

defmodule Template.Engine do
  @moduledoc """
  A lightweight Mustache-compatible template renderer.

  Supports `{{variable}}` substitution, `{{#section}}...{{/section}}` blocks
  that render when the value is truthy or iterate over lists, and
  `{{^inverted}}...{{/inverted}}` blocks that render when the value is falsy
  or an empty list. Values are HTML-escaped by default; no other tag types
  from the full Mustache spec are implemented.
  """

  alias Template.{Lexer, Token}

  @spec render(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def render(template, context) when is_binary(template) and is_map(context) do
    tokens = Lexer.tokenize(template)
    {result, _remaining} = render_tokens(tokens, context)
    {:ok, result}
  rescue
    error -> {:error, {:render_failed, error}}
  end

  defp render_tokens(tokens, context), do: do_render(tokens, context, "")

  defp do_render([], _ctx, acc), do: {acc, []}

  defp do_render([%Token{kind: :literal, value: v} | rest], ctx, acc) do
    do_render(rest, ctx, acc <> v)
  end

  defp do_render([%Token{kind: :variable, value: key} | rest], ctx, acc) do
    value = resolve(ctx, key) |> to_string() |> escape_html()
    do_render(rest, ctx, acc <> value)
  end

  defp do_render([%Token{kind: :section_open, value: key} | rest], ctx, acc) do
    {body_tokens, remaining} = collect_until_close(rest, key)
    value = resolve(ctx, key)

    rendered =
      cond do
        is_list(value) and value != [] ->
          Enum.map_join(value, "", fn item ->
            ctx_item = if is_map(item), do: Map.merge(ctx, item), else: Map.put(ctx, key, item)
            {rendered, _} = do_render(body_tokens, ctx_item, "")
            rendered
          end)

        value not in [nil, false, [], ""] ->
          child_ctx = if is_map(value), do: Map.merge(ctx, value), else: ctx
          {rendered, _} = do_render(body_tokens, child_ctx, "")
          rendered

        true ->
          ""
      end

    do_render(remaining, ctx, acc <> rendered)
  end

  defp do_render([%Token{kind: :inverted_open, value: key} | rest], ctx, acc) do
    {body_tokens, remaining} = collect_until_close(rest, key)
    value = resolve(ctx, key)

    rendered =
      if value in [nil, false, [], ""] do
        {r, _} = do_render(body_tokens, ctx, "")
        r
      else
        ""
      end

    do_render(remaining, ctx, acc <> rendered)
  end

  defp do_render([%Token{kind: :section_close} | rest], _ctx, acc) do
    {acc, rest}
  end

  defp collect_until_close(tokens, key) do
    {body, [_close | rest]} = Enum.split_while(tokens, fn
      %Token{kind: :section_close, value: ^key} -> false
      _ -> true
    end)

    {body, rest}
  end

  defp resolve(ctx, key) when is_binary(key), do: Map.get(ctx, key) || Map.get(ctx, String.to_existing_atom(key))
  rescue
    _ -> Map.get(ctx, key)

  defp escape_html(str) do
    str
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
```
