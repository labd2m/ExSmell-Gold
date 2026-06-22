**File:** `example_good_1301.md`

```elixir
defmodule Address do
  @moduledoc "A validated, normalized postal address."

  @enforce_keys [:line1, :city, :country_code]
  defstruct [:line1, :line2, :city, :state_province, :postal_code, :country_code]

  @type t :: %__MODULE__{
          line1: String.t(),
          line2: String.t() | nil,
          city: String.t(),
          state_province: String.t() | nil,
          postal_code: String.t() | nil,
          country_code: String.t()
        }
end

defmodule Address.Normalizer do
  @moduledoc """
  Normalizes raw address field strings into a consistent format:
  trimmed whitespace, uppercase country codes, and title-cased city names.
  """

  alias Address

  @spec normalize(Address.t()) :: Address.t()
  def normalize(%Address{} = address) do
    %Address{
      line1: normalize_line(address.line1),
      line2: normalize_optional_line(address.line2),
      city: normalize_city(address.city),
      state_province: normalize_optional_line(address.state_province),
      postal_code: normalize_postal_code(address.postal_code),
      country_code: normalize_country_code(address.country_code)
    }
  end

  defp normalize_line(line), do: line |> String.trim() |> compress_whitespace()
  defp normalize_optional_line(nil), do: nil
  defp normalize_optional_line(""), do: nil
  defp normalize_optional_line(line), do: normalize_line(line)

  defp normalize_city(city) do
    city
    |> String.trim()
    |> compress_whitespace()
    |> title_case()
  end

  defp normalize_postal_code(nil), do: nil
  defp normalize_postal_code(code), do: code |> String.trim() |> String.upcase()

  defp normalize_country_code(code), do: code |> String.trim() |> String.upcase()

  defp compress_whitespace(str), do: String.replace(str, ~r/\s+/, " ")

  defp title_case(str) do
    str
    |> String.split(" ")
    |> Enum.map(&capitalize_word/1)
    |> Enum.join(" ")
  end

  defp capitalize_word(""), do: ""
  defp capitalize_word(word), do: String.capitalize(word)
end

defmodule Address.Validator do
  @moduledoc """
  Validates a normalized address against country-specific rules.
  Returns a list of field-level error messages.
  """

  alias Address

  @country_rules %{
    "US" => %{requires_state: true, postal_format: ~r/^\d{5}(-\d{4})?$/},
    "CA" => %{requires_state: true, postal_format: ~r/^[A-Z]\d[A-Z] ?\d[A-Z]\d$/},
    "GB" => %{requires_state: false, postal_format: ~r/^[A-Z]{1,2}\d[A-Z\d]? ?\d[A-Z]{2}$/},
    "AU" => %{requires_state: true, postal_format: ~r/^\d{4}$/}
  }

  @type validation_result :: :ok | {:error, [String.t()]}

  @spec validate(Address.t()) :: validation_result()
  def validate(%Address{} = address) do
    errors =
      []
      |> check_line1(address)
      |> check_city(address)
      |> check_country_code(address)
      |> check_country_specific(address)

    if errors == [], do: :ok, else: {:error, Enum.reverse(errors)}
  end

  defp check_line1(errors, %Address{line1: line1}) when is_binary(line1) and line1 != "", do: errors
  defp check_line1(errors, _), do: ["line1 is required" | errors]

  defp check_city(errors, %Address{city: city}) when is_binary(city) and city != "", do: errors
  defp check_city(errors, _), do: ["city is required" | errors]

  defp check_country_code(errors, %Address{country_code: code})
       when is_binary(code) and byte_size(code) == 2, do: errors
  defp check_country_code(errors, _), do: ["country_code must be a 2-letter ISO code" | errors]

  defp check_country_specific(errors, %Address{country_code: code} = address) do
    case Map.get(@country_rules, code) do
      nil -> errors
      rules -> apply_country_rules(errors, address, rules)
    end
  end

  defp apply_country_rules(errors, address, rules) do
    errors
    |> maybe_check_state(address, rules)
    |> maybe_check_postal(address, rules)
  end

  defp maybe_check_state(errors, %Address{state_province: nil}, %{requires_state: true}) do
    ["state_province is required for this country" | errors]
  end

  defp maybe_check_state(errors, _, _), do: errors

  defp maybe_check_postal(errors, %Address{postal_code: nil}, _rules), do: errors

  defp maybe_check_postal(errors, %Address{postal_code: code}, %{postal_format: pattern}) do
    if String.match?(code, pattern), do: errors, else: ["postal_code format is invalid" | errors]
  end
end
```
