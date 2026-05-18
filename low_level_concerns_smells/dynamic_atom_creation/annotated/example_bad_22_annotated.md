# Annotated Example — Dynamic Atom Creation

| Field | Value |
|---|---|
| **Smell name** | Dynamic atom creation |
| **Expected smell location** | `AcceptLanguagePlug.parse_locales/1`, line where `String.to_atom/1` converts locale tags from the Accept-Language header |
| **Affected function(s)** | `AcceptLanguagePlug.parse_locales/1` |
| **Short explanation** | The `Accept-Language` HTTP header is provided by clients and can contain arbitrary locale tags. Splitting and converting each tag to an atom means any locale string a browser or API client sends—including malformed or invented tags—permanently allocates an atom on every unique request type. |

```elixir
defmodule MyApp.Plugs.AcceptLanguagePlug do
  @moduledoc """
  A Plug that parses the `Accept-Language` HTTP request header and assigns
  a prioritised list of locale atoms to `conn.assigns[:locales]`.
  Falls back to the application default locale when the header is absent
  or contains no supported languages.
  """

  @behaviour Plug

  import Plug.Conn

  require Logger

  @supported_locales [:en, :"en-GB", :"pt-BR", :pt, :es, :fr, :de, :ja, :zh, :"zh-TW"]
  @default_locale :en
  @max_header_length 256

  @impl Plug
  def init(opts) do
    %{
      supported: Keyword.get(opts, :supported, @supported_locales),
      default: Keyword.get(opts, :default, @default_locale),
      strict: Keyword.get(opts, :strict, false)
    }
  end

  @impl Plug
  def call(conn, %{supported: supported, default: default, strict: strict} = _opts) do
    locales =
      conn
      |> get_req_header("accept-language")
      |> List.first()
      |> parse_header(supported, default, strict)

    conn
    |> assign(:locales, locales)
    |> assign(:locale, List.first(locales, default))
  end

  defp parse_header(nil, _supported, default, _strict), do: [default]
  defp parse_header("", _supported, default, _strict), do: [default]

  defp parse_header(header, supported, default, strict) when is_binary(header) do
    if byte_size(header) > @max_header_length do
      Logger.warning("Accept-Language header exceeds max length, ignoring")
      [default]
    else
      parsed = parse_locales(header)
      matched = filter_supported(parsed, supported)

      cond do
        matched != [] -> matched
        strict -> [default]
        true -> [default]
      end
    end
  end

  # VALIDATION: SMELL START - Dynamic atom creation
  # VALIDATION: This is a smell because `String.to_atom/1` is applied to every
  # locale tag parsed out of the `Accept-Language` HTTP header. This header is
  # entirely client-controlled: browsers, API clients, bots, and fuzzing tools can
  # send arbitrary language tags like "x-custom-lang", "tlh" (Klingon), or randomly
  # generated strings. Each unique tag permanently allocates an atom. Because this
  # Plug runs on every HTTP request, a steady stream of requests with varied locale
  # strings will exhaust the atom table far faster than most other code paths.
  defp parse_locales(header) do
    header
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.map(fn part ->
      case String.split(part, ";q=") do
        [tag] -> {String.to_atom(tag), 1.0}
        [tag, q] -> {String.to_atom(tag), parse_quality(q)}
      end
    end)
    |> Enum.sort_by(fn {_tag, q} -> q end, :desc)
    |> Enum.map(fn {tag, _q} -> tag end)
  rescue
    _ -> []
  end
  # VALIDATION: SMELL END

  defp filter_supported(locales, supported) do
    Enum.filter(locales, &(&1 in supported))
  end

  defp parse_quality(q_string) do
    case Float.parse(q_string) do
      {q, _} when q >= 0.0 and q <= 1.0 -> q
      _ -> 0.0
    end
  end
end
```
