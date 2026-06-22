```elixir
defmodule Router.Pattern do
  @moduledoc false

  @type segment :: {:literal, String.t()} | {:param, atom()} | :wildcard

  @type t :: %__MODULE__{
          raw: String.t(),
          segments: [segment()]
        }

  defstruct [:raw, :segments]

  @spec compile(String.t()) :: {:ok, t()} | {:error, :invalid_pattern}
  def compile(pattern) when is_binary(pattern) do
    segments =
      pattern
      |> String.trim("/")
      |> String.split("/")
      |> Enum.map(&parse_segment/1)

    if Enum.any?(segments, &(&1 == :error)) do
      {:error, :invalid_pattern}
    else
      {:ok, %__MODULE__{raw: pattern, segments: segments}}
    end
  end

  defp parse_segment(":" <> name) when name != "" do
    {:param, String.to_existing_atom(name)}
  rescue
    _ -> {:param, String.to_atom(name)}
  end

  defp parse_segment("*"), do: :wildcard
  defp parse_segment(literal), do: {:literal, literal}
end

defmodule Router.PathMatcher do
  @moduledoc """
  Matches URL paths against compiled templates and extracts named parameters.

  Patterns use `:name` segments for named captures and `*` for a greedy
  wildcard that matches any remaining path. `match/2` returns a params map
  on success. `build/2` fills a pattern template with a params map to
  produce a concrete URL path, making it easy to generate links from route
  definitions.
  """

  alias Router.Pattern

  @type params :: %{atom() => String.t()}
  @type match_result :: {:ok, params()} | :no_match

  @spec match(String.t(), String.t()) :: match_result()
  def match(pattern, path) when is_binary(pattern) and is_binary(path) do
    with {:ok, compiled} <- Pattern.compile(pattern) do
      match_compiled(compiled, path)
    end
  end

  @spec match_compiled(Pattern.t(), String.t()) :: match_result()
  def match_compiled(%Pattern{} = pattern, path) when is_binary(path) do
    path_segments = path |> String.trim("/") |> String.split("/")
    do_match(pattern.segments, path_segments, %{})
  end

  @spec build(String.t(), params()) :: {:ok, String.t()} | {:error, :missing_param}
  def build(pattern, params) when is_binary(pattern) and is_map(params) do
    with {:ok, compiled} <- Pattern.compile(pattern) do
      build_path(compiled.segments, params, [])
    end
  end

  defp do_match([], [], params), do: {:ok, params}
  defp do_match([:wildcard | _], remaining, params) do
    {:ok, Map.put(params, :wildcard, Enum.join(remaining, "/"))}
  end
  defp do_match([{:literal, seg} | rest_pat], [seg | rest_path], params) do
    do_match(rest_pat, rest_path, params)
  end
  defp do_match([{:param, name} | rest_pat], [value | rest_path], params) do
    do_match(rest_pat, rest_path, Map.put(params, name, value))
  end
  defp do_match(_pattern, _path, _params), do: :no_match

  defp build_path([], _params, acc) do
    {:ok, "/" <> Enum.join(Enum.reverse(acc), "/")}
  end

  defp build_path([{:literal, seg} | rest], params, acc) do
    build_path(rest, params, [seg | acc])
  end

  defp build_path([{:param, name} | rest], params, acc) do
    case Map.fetch(params, name) do
      {:ok, value} -> build_path(rest, params, [to_string(value) | acc])
      :error -> {:error, :missing_param}
    end
  end

  defp build_path([:wildcard | _], params, acc) do
    wildcard_val = Map.get(params, :wildcard, "")
    {:ok, "/" <> Enum.join(Enum.reverse([wildcard_val | acc]), "/")}
  end
end

defmodule Router.Table do
  @moduledoc """
  A compiled routing table matching HTTP method + path to handler metadata.
  """

  alias Router.{PathMatcher, Pattern}

  @type route :: %{method: String.t(), pattern: Pattern.t(), handler: term()}

  @spec new([{String.t(), String.t(), term()}]) :: [route()]
  def new(definitions) when is_list(definitions) do
    Enum.map(definitions, fn {method, pattern_str, handler} ->
      {:ok, pattern} = Pattern.compile(pattern_str)
      %{method: String.upcase(method), pattern: pattern, handler: handler}
    end)
  end

  @spec lookup([route()], String.t(), String.t()) ::
          {:ok, term(), %{atom() => String.t()}} | :not_found
  def lookup(table, method, path) when is_list(table) do
    Enum.find_value(table, :not_found, fn route ->
      if route.method == String.upcase(method) do
        case PathMatcher.match_compiled(route.pattern, path) do
          {:ok, params} -> {:ok, route.handler, params}
          :no_match -> nil
        end
      end
    end)
  end
end
```
