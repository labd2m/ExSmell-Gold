# Annotated Example – Unnecessary Macros

| Field | Value |
|---|---|
| **Smell name** | Unnecessary macros |
| **Expected smell location** | `UserManagement.PhoneNormalizer` module, `normalize/1` macro |
| **Affected function(s)** | `normalize/1` |
| **Short explanation** | `normalize/1` strips and reformats a phone number string. String processing is entirely a runtime concern; a regular function with a clear name would be idiomatic Elixir and immediately testable without any `require` directive. |

```elixir
defmodule UserManagement.PhoneNormalizer do
  @moduledoc """
  Normalises and validates phone numbers supplied during user registration,
  profile updates, and two-factor authentication enrollment.
  Follows E.164 formatting conventions.
  """

  @default_country_code "+55"
  @e164_pattern ~r/^\+?[1-9]\d{7,14}$/
  @strip_pattern ~r/[\s\-\(\)\.]/

  # VALIDATION: SMELL START - Unnecessary macros
  # VALIDATION: This is a smell because `normalize/1` processes a runtime
  # string value using a series of `String` functions and regex operations.
  # None of this work can be performed at compile time, so using `defmacro`
  # instead of `def` adds `quote/unquote` boilerplate and a `require`
  # dependency on every call site without any benefit.
  defmacro normalize(raw_phone) do
    quote do
      stripped = Regex.replace(unquote(@strip_pattern), unquote(raw_phone), "")

      with_country =
        case stripped do
          "0" <> rest -> unquote(@default_country_code) <> rest
          "+" <> _ -> stripped
          digits -> unquote(@default_country_code) <> digits
        end

      with_country
    end
  end
  # VALIDATION: SMELL END

  def validate(phone) do
    require UserManagement.PhoneNormalizer
    normalized = UserManagement.PhoneNormalizer.normalize(phone)

    if Regex.match?(@e164_pattern, normalized) do
      {:ok, normalized}
    else
      {:error, "Invalid phone number format: #{phone}"}
    end
  end

  def format_display(phone) do
    require UserManagement.PhoneNormalizer
    normalized = UserManagement.PhoneNormalizer.normalize(phone)

    case normalized do
      "+55" <> rest when byte_size(rest) == 11 ->
        {area, number} = String.split_at(rest, 2)
        {prefix, suffix} = String.split_at(number, 5)
        "+55 (#{area}) #{prefix}-#{suffix}"

      "+1" <> rest when byte_size(rest) == 10 ->
        {area, number} = String.split_at(rest, 3)
        {prefix, suffix} = String.split_at(number, 3)
        "+1 (#{area}) #{prefix}-#{suffix}"

      other ->
        other
    end
  end

  def same_number?(phone_a, phone_b) do
    require UserManagement.PhoneNormalizer
    UserManagement.PhoneNormalizer.normalize(phone_a) ==
      UserManagement.PhoneNormalizer.normalize(phone_b)
  end

  def mask(phone) do
    require UserManagement.PhoneNormalizer
    normalized = UserManagement.PhoneNormalizer.normalize(phone)
    visible = String.slice(normalized, -4, 4)
    masked_len = max(String.length(normalized) - 4, 0)
    String.duplicate("*", masked_len) <> visible
  end

  def bulk_validate(phones) when is_list(phones) do
    Enum.reduce(phones, %{valid: [], invalid: []}, fn phone, acc ->
      case validate(phone) do
        {:ok, normalized} -> Map.update!(acc, :valid, &[normalized | &1])
        {:error, _} -> Map.update!(acc, :invalid, &[phone | &1])
      end
    end)
  end

  def infer_country_code(phone) do
    require UserManagement.PhoneNormalizer
    normalized = UserManagement.PhoneNormalizer.normalize(phone)

    cond do
      String.starts_with?(normalized, "+55") -> "BR"
      String.starts_with?(normalized, "+1") -> "US/CA"
      String.starts_with?(normalized, "+44") -> "GB"
      String.starts_with?(normalized, "+49") -> "DE"
      true -> "unknown"
    end
  end
end
```
