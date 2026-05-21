# Annotated Bad Example 22: Untested Polymorphic Behaviors

## Metadata

- **Smell name**: Untested Polymorphic Behaviors
- **Expected smell location**: `Crm.ContactIndex.build_search_key/1`
- **Affected function(s)**: `build_search_key/1`
- **Short explanation**: The function calls `String.downcase/1` on the result of `to_string/1` applied to `identifier`, without any guard clause. Passing a `Map` or `List` raises `Protocol.UndefinedError`, while passing an integer silently produces a numeric search key (e.g., `"12345"`). In a CRM context, integers are legitimate contact IDs, but silently accepting them and treating them identically to a string key creates invisible collision risks (integer `123` and string `"123"` would generate the same key). The function should restrict the type of `identifier` explicitly.

## Code

```elixir
defmodule Crm.ContactIndex do
  @moduledoc """
  Manages the contact search index for the CRM system.
  Provides key generation, normalization, and look-up utilities used by
  the full-text search pipeline and the duplicate-detection service.
  """

  @index_namespace "contact"
  @email_domain_blocklist ~w(example.com test.com invalid.org)
  @phone_digit_pattern ~r/\D/

  @doc """
  Builds a normalized search key for a contact identifier.
  Used to de-duplicate contacts and power prefix-search look-ups.

  ## Parameters
    - `identifier`: A contact email address, phone number string, or external ID.
  """
  # VALIDATION: SMELL START - Untested Polymorphic Behaviors
  # VALIDATION: This is a smell because `to_string/1` is called on `identifier`
  # without any guard clause. The `String.Chars` protocol is not implemented for
  # `Map`, `List`, or `Tuple`, so passing those types raises `Protocol.UndefinedError`
  # at runtime rather than a clear `FunctionClauseError` at the function boundary.
  # More subtly, passing an integer contact ID (e.g., `123`) silently generates the
  # key `"contact:123"`, which is identical to what the string `"123"` would produce,
  # creating invisible collision risks in the search index. The function should use
  # `is_binary(identifier)` as a guard to enforce the intended contract.
  def build_search_key(identifier) do
    normalized =
      identifier
      |> to_string()
      |> String.downcase()
      |> String.trim()

    "#{@index_namespace}:#{normalized}"
  end
  # VALIDATION: SMELL END

  @doc """
  Normalizes an email address for storage and indexing.
  Returns `{:ok, normalized_email}` or `{:error, reason}`.
  """
  def normalize_email(email) when is_binary(email) do
    normalized =
      email
      |> String.downcase()
      |> String.trim()

    domain = normalized |> String.split("@") |> List.last()

    cond do
      not String.contains?(normalized, "@") ->
        {:error, :invalid_email_format}

      domain in @email_domain_blocklist ->
        {:error, :blocklisted_domain}

      true ->
        {:ok, normalized}
    end
  end

  @doc """
  Normalizes a phone number by stripping all non-digit characters.
  """
  def normalize_phone(phone) when is_binary(phone) do
    digits = Regex.replace(@phone_digit_pattern, phone, "")

    if String.length(digits) >= 8 do
      {:ok, digits}
    else
      {:error, :phone_too_short}
    end
  end

  @doc """
  Returns a list of candidate search keys for a contact given multiple
  potential identifiers (email, phone, external IDs).
  """
  def candidate_keys(%{email: email, phone: phone, external_ids: external_ids})
      when is_binary(email) and is_binary(phone) and is_list(external_ids) do
    email_key =
      case normalize_email(email) do
        {:ok, e} -> [build_search_key(e)]
        _ -> []
      end

    phone_key =
      case normalize_phone(phone) do
        {:ok, p} -> [build_search_key(p)]
        _ -> []
      end

    external_keys = Enum.map(external_ids, &build_search_key/1)

    email_key ++ phone_key ++ external_keys
  end

  @doc """
  Checks whether two contacts are likely duplicates based on shared search keys.
  """
  def likely_duplicate?(contact_a, contact_b)
      when is_map(contact_a) and is_map(contact_b) do
    keys_a = MapSet.new(candidate_keys(contact_a))
    keys_b = MapSet.new(candidate_keys(contact_b))

    not MapSet.disjoint?(keys_a, keys_b)
  end

  @doc """
  Returns the index namespace prefix used for all contact keys.
  """
  def namespace, do: @index_namespace
end
```
