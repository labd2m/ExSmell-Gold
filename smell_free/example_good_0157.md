```elixir
defmodule Slug do
  @moduledoc """
  Generates URL-safe slugs from arbitrary UTF-8 strings and enforces
  uniqueness by appending an incrementing suffix when a collision exists.

  Transliteration converts common accented characters to their ASCII
  equivalents before normalisation so that "Ångström" becomes "angstrom"
  rather than an empty string.
  """

  @transliteration_map %{
    "à" => "a", "á" => "a", "â" => "a", "ã" => "a", "ä" => "a", "å" => "a",
    "è" => "e", "é" => "e", "ê" => "e", "ë" => "e",
    "ì" => "i", "í" => "i", "î" => "i", "ï" => "i",
    "ò" => "o", "ó" => "o", "ô" => "o", "õ" => "o", "ö" => "o",
    "ù" => "u", "ú" => "u", "û" => "u", "ü" => "u",
    "ñ" => "n", "ç" => "c", "ý" => "y", "ÿ" => "y",
    "ß" => "ss", "æ" => "ae", "œ" => "oe", "ø" => "o", "å" => "a"
  }

  @spec generate(String.t()) :: String.t()
  def generate(input) when is_binary(input) do
    input
    |> String.downcase()
    |> transliterate()
    |> String.replace(~r/[^a-z0-9\s-]/, "")
    |> String.replace(~r/[\s-]+/, "-")
    |> String.trim("-")
    |> truncate(80)
  end

  @spec unique(String.t(), (String.t() -> boolean())) :: String.t()
  def unique(input, exists_fn) when is_binary(input) and is_function(exists_fn, 1) do
    base = generate(input)
    resolve_unique(base, exists_fn, 0)
  end

  @spec valid?(String.t()) :: boolean()
  def valid?(slug) when is_binary(slug) do
    String.match?(slug, ~r/\A[a-z0-9][a-z0-9-]*[a-z0-9]\z/) and
      not String.contains?(slug, "--") and
      byte_size(slug) <= 255
  end

  def valid?(_), do: false

  @spec append_suffix(String.t(), pos_integer()) :: String.t()
  def append_suffix(slug, n) when is_binary(slug) and is_integer(n) and n > 0 do
    base = slug |> String.replace(~r/-\d+$/, "") |> truncate(76)
    "#{base}-#{n}"
  end

  defp resolve_unique(candidate, exists_fn, 0) do
    if exists_fn.(candidate) do
      resolve_unique(candidate, exists_fn, 1)
    else
      candidate
    end
  end

  defp resolve_unique(base, exists_fn, n) do
    candidate = append_suffix(base, n)

    if exists_fn.(candidate) do
      resolve_unique(base, exists_fn, n + 1)
    else
      candidate
    end
  end

  defp transliterate(input) do
    Enum.reduce(@transliteration_map, input, fn {from, to}, acc ->
      String.replace(acc, from, to)
    end)
  end

  defp truncate(str, max_length) when byte_size(str) <= max_length, do: str

  defp truncate(str, max_length) do
    str
    |> String.slice(0, max_length)
    |> String.replace(~r/-[^-]*$/, "")
  end
end
```
