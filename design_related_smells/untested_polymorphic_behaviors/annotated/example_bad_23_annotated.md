# Annotated Bad Example 23: Untested Polymorphic Behaviors

## Metadata

- **Smell name**: Untested Polymorphic Behaviors
- **Expected smell location**: `Analytics.DimensionFormatter.format_dimension_value/2`
- **Affected function(s)**: `format_dimension_value/2`
- **Short explanation**: The function's `:default` clause calls `to_string/1` on `value` without any guard clause, relying on the `String.Chars` protocol. Callers can pass types that do not implement the protocol (e.g., `Map`, `List`) and receive a `Protocol.UndefinedError` instead of a clear boundary error. Additionally, types that do implement the protocol, such as a `URI` struct or a `Float`, will silently produce formatted dimension labels (e.g., `"3.14e0"`) that are meaningless in an analytics context, polluting reports without any warning.

## Code

```elixir
defmodule Analytics.DimensionFormatter do
  @moduledoc """
  Formats dimension values for analytics reports and dashboard visualizations.
  Dimensions describe the categorical axes of metrics (e.g., country, channel,
  product category, plan tier).

  Used by the query result renderer and the chart data transformer.
  """

  @unknown_label "(unknown)"
  @null_label "(none)"
  @truncation_suffix "…"
  @max_label_length 40

  @doc """
  Formats a dimension value for display according to the dimension type.

  ## Parameters
    - `dimension_type`: An atom identifying the dimension (e.g., `:country`, `:channel`).
    - `value`: The raw dimension value to format.
  """
  def format_dimension_value(:country, nil), do: @unknown_label
  def format_dimension_value(:country, code) when is_binary(code) and byte_size(code) == 2 do
    String.upcase(code)
  end
  def format_dimension_value(:country, _), do: @unknown_label

  def format_dimension_value(:currency, nil), do: @unknown_label
  def format_dimension_value(:currency, code) when is_binary(code) and byte_size(code) == 3 do
    String.upcase(code)
  end
  def format_dimension_value(:currency, _), do: @unknown_label

  def format_dimension_value(:plan_tier, nil), do: @null_label
  def format_dimension_value(:plan_tier, tier) when is_atom(tier) do
    tier |> Atom.to_string() |> String.capitalize()
  end
  def format_dimension_value(:plan_tier, tier) when is_binary(tier) do
    String.capitalize(tier)
  end

  def format_dimension_value(:boolean_flag, true), do: "Yes"
  def format_dimension_value(:boolean_flag, false), do: "No"
  def format_dimension_value(:boolean_flag, nil), do: @unknown_label

  # VALIDATION: SMELL START - Untested Polymorphic Behaviors
  # VALIDATION: This is a smell because the catch-all clause calls `to_string/1`
  # on `value` without any guard clause. The `String.Chars` protocol is not
  # implemented for all Elixir types — `Map`, `List`, and `Tuple` will raise
  # `Protocol.UndefinedError` at runtime. More critically, types that DO implement
  # the protocol (e.g., `Float`, `URI`, `Integer`) are silently accepted and produce
  # labels like `"3.14e0"` or `"http://example.com"` that appear in dashboards as
  # valid dimension values, corrupting analytics without any error signal. The
  # fallback should restrict to `is_binary` and `is_atom` at minimum.
  def format_dimension_value(_dimension_type, nil), do: @null_label
  def format_dimension_value(_dimension_type, value) do
    value
    |> to_string()
    |> truncate_label()
  end
  # VALIDATION: SMELL END

  @doc """
  Truncates a label string to the maximum allowed display length.
  """
  def truncate_label(label) when is_binary(label) do
    if String.length(label) > @max_label_length do
      String.slice(label, 0, @max_label_length - 1) <> @truncation_suffix
    else
      label
    end
  end

  @doc """
  Formats a list of dimension values as a comma-separated label for grouped reports.
  """
  def format_dimension_group(dimension_type, values) when is_atom(dimension_type) and is_list(values) do
    values
    |> Enum.map(&format_dimension_value(dimension_type, &1))
    |> Enum.join(", ")
  end

  @doc """
  Returns the sort key for a dimension value, used in deterministic ordering
  of report rows.
  """
  def sort_key(:country, code) when is_binary(code), do: String.downcase(code)
  def sort_key(:plan_tier, tier) when is_atom(tier), do: tier_sort_order(tier)
  def sort_key(_, nil), do: "zzz"
  def sort_key(_, value) when is_binary(value), do: String.downcase(value)
  def sort_key(_, _), do: "zzz"

  defp tier_sort_order(:enterprise), do: "0"
  defp tier_sort_order(:pro), do: "1"
  defp tier_sort_order(:starter), do: "2"
  defp tier_sort_order(:free), do: "3"
  defp tier_sort_order(_), do: "9"
end
```
