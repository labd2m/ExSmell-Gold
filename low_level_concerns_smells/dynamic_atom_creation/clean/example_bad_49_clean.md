```elixir
defmodule I18n.LocaleResolver do
  @moduledoc """
  Resolves the best matching locale for an incoming request based on the
  Accept-Language header, stored user preference, and available translations.
  """

  require Logger

  alias I18n.{TranslationStore, UserPreferenceRepo, FallbackChain}

  @default_locale :en_US
  @supported_locales ~w(en_US en_GB pt_BR es_ES es_MX fr_FR de_DE ja_JP zh_CN)

  @spec resolve(map()) :: {:ok, atom()} | {:error, term()}
  def resolve(conn_assigns) do
    candidates = build_candidate_list(conn_assigns)

    case find_supported(candidates) do
      {:ok, locale} ->
        Logger.debug("Locale resolved", locale: locale)
        {:ok, locale}

      :none ->
        Logger.debug("No matching locale, using default", default: @default_locale)
        {:ok, @default_locale}
    end
  end

  @spec translate(atom(), String.t(), map()) :: String.t()
  def translate(locale, key, bindings \\ %{}) do
    case TranslationStore.fetch(locale, key) do
      {:ok, template} ->
        interpolate(template, bindings)

      {:error, :not_found} ->
        fallback = FallbackChain.for(locale)
        translate_with_fallback(fallback, key, bindings)
    end
  end

  defp build_candidate_list(assigns) do
    [
      assigns[:user_locale],
      parse_accept_language(assigns[:accept_language]),
      assigns[:org_default_locale]
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  defp parse_accept_language(nil), do: []

  defp parse_accept_language(header) when is_binary(header) do
    header
    |> String.split(",")
    |> Enum.map(&parse_language_tag/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(fn {_tag, q} -> -q end)
    |> Enum.map(fn {tag, _q} -> tag end)
  end

  defp parse_accept_language(_), do: []

  defp parse_language_tag(entry) do
    case String.split(String.trim(entry), ";q=") do
      [tag] -> {normalise_tag(tag), 1.0}
      [tag, q] ->
        case Float.parse(q) do
          {val, _} -> {normalise_tag(tag), val}
          :error -> nil
        end
      _ -> nil
    end
  end

  defp normalise_tag(tag) do
    tag
    |> String.trim()
    |> String.replace("-", "_")
  end

  defp find_supported([]), do: :none

  defp find_supported([candidate | rest]) do
    case resolve_locale(candidate) do
      {:ok, locale} -> {:ok, locale}
      {:error, _} -> find_supported(rest)
    end
  end

  defp resolve_locale(tag) when is_binary(tag) do
    locale_atom = String.to_atom(tag)

    if Atom.to_string(locale_atom) in @supported_locales do
      {:ok, locale_atom}
    else
      {:error, :unsupported_locale}
    end
  end

  defp resolve_locale(tag) when is_atom(tag) do
    if Atom.to_string(tag) in @supported_locales,
      do: {:ok, tag},
      else: {:error, :unsupported_locale}
  end

  defp resolve_locale(_), do: {:error, :invalid_locale}

  defp translate_with_fallback([], key, _bindings) do
    Logger.warning("Missing translation key", key: key)
    key
  end

  defp translate_with_fallback([locale | rest], key, bindings) do
    case TranslationStore.fetch(locale, key) do
      {:ok, template} -> interpolate(template, bindings)
      {:error, _} -> translate_with_fallback(rest, key, bindings)
    end
  end

  defp interpolate(template, bindings) when map_size(bindings) == 0, do: template

  defp interpolate(template, bindings) do
    Enum.reduce(bindings, template, fn {k, v}, acc ->
      String.replace(acc, "{{#{k}}}", to_string(v))
    end)
  end
end
```
