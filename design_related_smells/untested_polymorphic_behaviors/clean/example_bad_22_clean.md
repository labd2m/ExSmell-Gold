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
  def build_search_key(identifier) do
    normalized =
      identifier
      |> to_string()
      |> String.downcase()
      |> String.trim()

    "#{@index_namespace}:#{normalized}"
  end

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
