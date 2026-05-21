# Annotated Bad Example 19: Untested Polymorphic Behaviors

## Metadata

- **Smell name**: Untested Polymorphic Behaviors
- **Expected smell location**: `Accounts.UserProfile.normalize_display_name/1`
- **Affected function(s)**: `normalize_display_name/1`
- **Short explanation**: The function calls `String.trim/1` on the result of `to_string/1` applied to the `name` argument, without any guard clause. This silently accepts integers, floats, and atoms (converting them via `String.Chars`), and raises `Protocol.UndefinedError` for maps, lists, and tuples. In a user management context, accepting an integer or float as a display name (producing `"42"` or `"3.14"`) is semantically wrong and undetectable without explicit guards, which can lead to corrupt user profile data being stored silently.

## Code

```elixir
defmodule Accounts.UserProfile do
  @moduledoc """
  Handles user profile operations including display name normalization,
  avatar URL validation, and preference management.

  Used by the registration flow, the settings panel, and the admin user editor.
  """

  @max_display_name_length 64
  @min_display_name_length 2
  @allowed_avatar_schemes ["https"]

  @doc """
  Returns a changeset-like validation result for a profile update payload.
  """
  def validate_profile_update(%{display_name: name} = params) do
    with {:ok, normalized_name} <- validate_display_name(name),
         :ok <- validate_avatar_url(Map.get(params, :avatar_url)) do
      {:ok, Map.put(params, :display_name, normalized_name)}
    end
  end

  @doc """
  Validates and normalizes a display name.
  Returns `{:ok, normalized}` or `{:error, reason}`.
  """
  def validate_display_name(name) do
    normalized = normalize_display_name(name)
    len = String.length(normalized)

    cond do
      len < @min_display_name_length ->
        {:error, :display_name_too_short}

      len > @max_display_name_length ->
        {:error, :display_name_too_long}

      Regex.match?(~r/[<>"'&]/, normalized) ->
        {:error, :display_name_invalid_chars}

      true ->
        {:ok, normalized}
    end
  end

  @doc """
  Normalizes a raw display name value by trimming surrounding whitespace
  and collapsing internal runs of whitespace to a single space.
  """
  # VALIDATION: SMELL START - Untested Polymorphic Behaviors
  # VALIDATION: This is a smell because `to_string/1` is called on `name` without
  # any guard clause. The `String.Chars` protocol is not implemented for `Map`,
  # `List`, or `Tuple`, causing a `Protocol.UndefinedError` at runtime if such
  # values are passed. More subtly, passing an `Integer` (e.g., `42`) or `Float`
  # silently produces a valid-looking display name (`"42"`) that passes all the
  # length and character validations below, resulting in corrupt profile data being
  # stored. The function should use `is_binary(name)` as a guard to enforce the
  # intended contract.
  def normalize_display_name(name) do
    name
    |> to_string()
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
  end
  # VALIDATION: SMELL END

  @doc """
  Validates an optional avatar URL. Nil or empty string values are accepted.
  """
  def validate_avatar_url(nil), do: :ok
  def validate_avatar_url(""), do: :ok

  def validate_avatar_url(url) when is_binary(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme not in @allowed_avatar_schemes ->
        {:error, :avatar_url_insecure_scheme}

      is_nil(uri.host) or uri.host == "" ->
        {:error, :avatar_url_missing_host}

      true ->
        :ok
    end
  end

  def validate_avatar_url(_), do: {:error, :avatar_url_invalid_type}

  @doc """
  Builds a gravatar URL for a given email address.
  """
  def gravatar_url(email, size \\ 80) when is_binary(email) and is_integer(size) do
    hash =
      email
      |> String.downcase()
      |> String.trim()
      |> then(&:crypto.hash(:md5, &1))
      |> Base.encode16(case: :lower)

    "https://www.gravatar.com/avatar/#{hash}?s=#{size}&d=identicon"
  end

  @doc """
  Returns the initials for a display name (up to two characters).
  """
  def initials(display_name) when is_binary(display_name) do
    display_name
    |> String.split()
    |> Enum.take(2)
    |> Enum.map(&String.first/1)
    |> Enum.join()
    |> String.upcase()
  end

  @doc """
  Returns the user's preferred locale or the system default.
  """
  def resolve_locale(%{locale: locale}) when is_binary(locale) and locale != "", do: locale
  def resolve_locale(_), do: "en"
end
```
