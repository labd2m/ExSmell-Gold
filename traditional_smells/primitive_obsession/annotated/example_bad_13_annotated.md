# Annotated Example: Primitive Obsession

## Metadata

- **Smell Name**: Primitive Obsession
- **Expected Smell Location**: `create_profile/4`, `display_name/3`, `format_for_salutation/3`, `update_name/3`, `search_by_name/3`
- **Affected Function(s)**: All public functions in `UserManagement.ProfileService`
- **Explanation**: A person's name is broken into individual `String.t()` primitives (`first_name`, `last_name`, optionally `middle_name`) rather than being wrapped in a `%PersonName{}` struct. Every function that needs to work with names must accept and forward multiple strings, formatting conventions are re-implemented in each function, and there is no single type to attach validation or locale-specific rendering.

## Code

```elixir
defmodule UserManagement.ProfileService do
  @moduledoc """
  Manages user profile creation, display-name formatting, and name-based
  search within the user management subsystem. Handles both Western
  (first–last) and Eastern (last–first) name ordering conventions.
  """

  require Logger

  @max_name_length 100
  @name_format_locales_reversed ~w(zh_CN zh_TW ja_JP ko_KR vi_VN)

  # VALIDATION: SMELL START - Primitive Obsession
  # VALIDATION: This is a smell because a person's name is decomposed into raw
  # VALIDATION: `String.t()` primitives — `first_name`, `last_name`, and
  # VALIDATION: optionally `middle_name` — instead of a `%PersonName{}` struct.
  # VALIDATION: All functions carry and manipulate these strings independently,
  # VALIDATION: locale-aware formatting logic is duplicated, and callers
  # VALIDATION: frequently swap first/last name order with no type-level protection.
  @spec create_profile(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, String.t()}
  def create_profile(user_id, first_name, last_name, locale \\ "en_US") do
    with :ok <- validate_name_part(first_name, "first_name"),
         :ok <- validate_name_part(last_name, "last_name") do
      profile = %{
        id: user_id,
        first_name: String.trim(first_name),
        last_name: String.trim(last_name),
        locale: locale,
        display_name: display_name(first_name, last_name, locale),
        created_at: DateTime.utc_now()
      }

      Logger.info("Profile created for #{display_name(first_name, last_name, locale)} (#{user_id})")
      {:ok, profile}
    end
  end

  @spec display_name(String.t(), String.t(), String.t()) :: String.t()
  def display_name(first_name, last_name, locale \\ "en_US") do
    first = String.trim(first_name)
    last = String.trim(last_name)

    if locale in @name_format_locales_reversed do
      "#{last}#{first}"
    else
      "#{first} #{last}"
    end
  end

  @spec format_for_salutation(String.t(), String.t(), String.t()) :: String.t()
  def format_for_salutation(first_name, last_name, locale \\ "en_US") do
    first = String.trim(first_name)
    last = String.trim(last_name)

    case locale do
      "en_US" -> "Dear #{first},"
      "en_GB" -> "Dear #{first},"
      "de_DE" -> "Sehr geehrte/r #{last},"
      "fr_FR" -> "Cher/Chère #{first},"
      "ja_JP" -> "#{last}#{first}様"
      "zh_CN" -> "尊敬的#{last}#{first}："
      _ -> "Dear #{first},"
    end
  end

  @spec update_name(map(), String.t(), String.t()) ::
          {:ok, map()} | {:error, String.t()}
  def update_name(profile, new_first_name, new_last_name) do
    with :ok <- validate_name_part(new_first_name, "first_name"),
         :ok <- validate_name_part(new_last_name, "last_name") do
      old_display = display_name(profile.first_name, profile.last_name, profile.locale)
      new_display = display_name(new_first_name, new_last_name, profile.locale)

      updated =
        profile
        |> Map.put(:first_name, String.trim(new_first_name))
        |> Map.put(:last_name, String.trim(new_last_name))
        |> Map.put(:display_name, new_display)
        |> Map.put(:updated_at, DateTime.utc_now())

      Logger.info("Name updated for #{profile.id}: #{old_display} → #{new_display}")
      {:ok, updated}
    end
  end

  @spec search_by_name(list(map()), String.t(), String.t()) :: list(map())
  def search_by_name(profiles, first_name, last_name) do
    query_first = first_name |> String.trim() |> String.downcase()
    query_last = last_name |> String.trim() |> String.downcase()

    Enum.filter(profiles, fn profile ->
      pf = profile.first_name |> String.downcase()
      pl = profile.last_name |> String.downcase()

      (query_first == "" or String.contains?(pf, query_first)) and
        (query_last == "" or String.contains?(pl, query_last))
    end)
  end

  @spec initials(String.t(), String.t()) :: String.t()
  def initials(first_name, last_name) do
    fi = first_name |> String.trim() |> String.first() |> String.upcase()
    li = last_name |> String.trim() |> String.first() |> String.upcase()
    "#{fi}#{li}"
  end
  # VALIDATION: SMELL END

  defp validate_name_part(value, field) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" ->
        {:error, "#{field} cannot be blank"}

      String.length(trimmed) > @max_name_length ->
        {:error, "#{field} exceeds maximum length of #{@max_name_length} characters"}

      not String.match?(trimmed, ~r/^[\p{L}\p{M}'\-\s.]+$/u) ->
        {:error, "#{field} contains invalid characters"}

      true ->
        :ok
    end
  end
end
```
