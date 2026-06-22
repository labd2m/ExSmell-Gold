```elixir
defmodule Search.QueryParser do
  @moduledoc """
  Parses raw search query strings into structured query representations
  for use in full-text and faceted search backends.
  """

  @type filter :: %{field: String.t(), value: String.t()}
  @type parsed_query :: %{
    terms: [String.t()],
    filters: [filter()],
    excluded_terms: [String.t()],
    phrase: String.t() | nil
  }

  @spec parse(String.t()) :: {:ok, parsed_query()} | {:error, String.t()}
  def parse(raw) when is_binary(raw) do
    trimmed = String.trim(raw)

    if trimmed == "" do
      {:error, "Search query must not be empty"}
    else
      {:ok, extract_query_parts(trimmed)}
    end
  end

  @spec to_display_string(parsed_query()) :: String.t()
  def to_display_string(%{terms: terms, filters: filters, excluded_terms: excluded, phrase: phrase}) do
    parts =
      [
        format_phrase(phrase),
        format_terms(terms),
        format_exclusions(excluded),
        format_filters(filters)
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(parts, " ")
  end

  @spec extract_query_parts(String.t()) :: parsed_query()
  defp extract_query_parts(raw) do
    tokens = String.split(raw, ~r/\s+/, trim: true)

    %{
      terms: collect_plain_terms(tokens),
      filters: collect_filters(tokens),
      excluded_terms: collect_exclusions(tokens),
      phrase: extract_phrase(raw)
    }
  end

  @spec collect_plain_terms([String.t()]) :: [String.t()]
  defp collect_plain_terms(tokens) do
    tokens
    |> Enum.reject(&String.starts_with?(&1, "-"))
    |> Enum.reject(&String.contains?(&1, ":"))
    |> Enum.map(&String.downcase/1)
  end

  @spec collect_filters([String.t()]) :: [filter()]
  defp collect_filters(tokens) do
    tokens
    |> Enum.filter(&String.contains?(&1, ":"))
    |> Enum.flat_map(&parse_filter/1)
  end

  @spec collect_exclusions([String.t()]) :: [String.t()]
  defp collect_exclusions(tokens) do
    tokens
    |> Enum.filter(&String.starts_with?(&1, "-"))
    |> Enum.reject(&String.contains?(&1, ":"))
    |> Enum.map(&String.trim_leading(&1, "-"))
  end

  @spec extract_phrase(String.t()) :: String.t() | nil
  defp extract_phrase(raw) do
    case Regex.run(~r/"([^"]+)"/, raw) do
      [_, phrase] -> phrase
      _ -> nil
    end
  end

  @spec parse_filter(String.t()) :: [filter()]
  defp parse_filter(token) do
    case String.split(token, ":", parts: 2) do
      [field, value] when field != "" and value != "" ->
        [%{field: String.downcase(field), value: value}]
      _ ->
        []
    end
  end

  @spec format_phrase(String.t() | nil) :: String.t() | nil
  defp format_phrase(nil), do: nil
  defp format_phrase(phrase), do: ~s("#{phrase}")

  @spec format_terms([String.t()]) :: String.t() | nil
  defp format_terms([]), do: nil
  defp format_terms(terms), do: Enum.join(terms, " ")

  @spec format_exclusions([String.t()]) :: String.t() | nil
  defp format_exclusions([]), do: nil
  defp format_exclusions(terms), do: terms |> Enum.map(&"-#{&1}") |> Enum.join(" ")

  @spec format_filters([filter()]) :: String.t() | nil
  defp format_filters([]), do: nil
  defp format_filters(filters), do: filters |> Enum.map(&"#{&1.field}:#{&1.value}") |> Enum.join(" ")
end
```
