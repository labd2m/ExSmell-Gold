```elixir
defmodule I18n.LanguageTag do
  @moduledoc false

  @type t :: %__MODULE__{
          language: String.t(),
          region: String.t() | nil,
          quality: float()
        }

  defstruct [:language, :region, quality: 1.0]

  @spec to_locale(t()) :: String.t()
  def to_locale(%__MODULE__{language: lang, region: nil}), do: lang
  def to_locale(%__MODULE__{language: lang, region: region}), do: "#{lang}-#{region}"
end

defmodule I18n.LanguageNegotiator do
  @moduledoc """
  Parses `Accept-Language` HTTP headers and selects the best available
  locale using quality-factor weighted matching.

  Matching follows RFC 4647 lookup scheme: a tag of `en-US` is first
  matched exactly, then the language-only prefix `en` is tried, then
  the wildcard `*`. The first available locale satisfying any of these
  lookups wins. When no match is found, the configured default is returned.
  """

  alias I18n.LanguageTag

  @type locale :: String.t()

  @spec negotiate(String.t(), [locale()], locale()) :: locale()
  def negotiate(accept_language_header, available_locales, default_locale)
      when is_binary(accept_language_header) and is_list(available_locales) do
    tags = parse(accept_language_header)
    available_set = MapSet.new(Enum.map(available_locales, &String.downcase/1))

    Enum.find_value(tags, default_locale, fn tag ->
      exact = LanguageTag.to_locale(tag) |> String.downcase()
      lang_only = tag.language |> String.downcase()

      cond do
        MapSet.member?(available_set, exact) ->
          find_original(available_locales, exact)

        MapSet.member?(available_set, lang_only) ->
          find_original(available_locales, lang_only)

        tag.language == "*" and available_locales != [] ->
          List.first(available_locales)

        true ->
          nil
      end
    end)
  end

  @spec parse(String.t()) :: [LanguageTag.t()]
  def parse(header) when is_binary(header) do
    header
    |> String.split(",")
    |> Enum.map(&parse_tag/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& -&1.quality)
  end

  @spec preferred_locales(String.t()) :: [String.t()]
  def preferred_locales(header) when is_binary(header) do
    header |> parse() |> Enum.map(&LanguageTag.to_locale/1)
  end

  defp parse_tag(segment) do
    case String.split(String.trim(segment), ";", parts: 2) do
      [tag_str, quality_str] ->
        with tag when not is_nil(tag) <- parse_language_tag(tag_str),
             quality <- parse_quality(quality_str) do
          %{tag | quality: quality}
        end

      [tag_str] ->
        parse_language_tag(tag_str)
    end
  end

  defp parse_language_tag(tag_str) do
    normalized = tag_str |> String.trim() |> String.downcase()

    case String.split(normalized, "-", parts: 2) do
      ["*"] ->
        %LanguageTag{language: "*"}

      [language] when language =~ ~r/\A[a-z]{2,8}\z/ ->
        %LanguageTag{language: language}

      [language, region] when language =~ ~r/\A[a-z]{2,8}\z/ ->
        %LanguageTag{language: language, region: String.upcase(region)}

      _ ->
        nil
    end
  end

  defp parse_quality("q=" <> value) do
    case Float.parse(String.trim(value)) do
      {q, ""} when q >= 0.0 and q <= 1.0 -> q
      _ -> 1.0
    end
  end

  defp parse_quality(_), do: 1.0

  defp find_original(locales, downcased) do
    Enum.find(locales, &(String.downcase(&1) == downcased))
  end
end
```
