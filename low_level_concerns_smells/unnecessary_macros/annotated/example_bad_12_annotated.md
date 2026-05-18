# Annotated Example 12 — Unnecessary Macros

## Metadata

- **Smell name:** Unnecessary macros
- **Expected smell location:** `defmacro slugify/1` inside `UserManagement.StringHelpers`
- **Affected function(s):** `slugify/1`
- **Short explanation:** The macro converts a string to a URL-safe slug using only `String` module calls and a regex replacement — all purely runtime string operations. A plain function is the right tool.

---

```elixir
defmodule UserManagement.StringHelpers do
  @moduledoc """
  String processing utilities used across the user management context,
  including profile generation, handle creation, and display formatting.
  """

  # VALIDATION: SMELL START - Unnecessary macros
  # VALIDATION: This is a smell because slugify/1 only calls String functions
  # and Regex.replace on a runtime string. All operations occur at runtime;
  # no AST manipulation is needed. A def function is the appropriate choice.
  defmacro slugify(text) do
    quote do
      unquote(text)
      |> String.downcase()
      |> String.replace(~r/[^\w\s-]/, "")
      |> String.replace(~r/[\s_]+/, "-")
      |> String.replace(~r/-+/, "-")
      |> String.trim("-")
    end
  end
  # VALIDATION: SMELL END

  @doc """
  Capitalises the first letter of each word in the string.
  """
  @spec title_case(String.t()) :: String.t()
  def title_case(text) when is_binary(text) do
    text
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  @doc """
  Returns the initials for a full name string (up to 2 characters).
  """
  @spec initials(String.t()) :: String.t()
  def initials(full_name) when is_binary(full_name) do
    full_name
    |> String.split()
    |> Enum.take(2)
    |> Enum.map_join("", fn word -> String.first(word) |> String.upcase() end)
  end

  @doc """
  Sanitises display names by removing non-printable or disallowed characters.
  """
  @spec sanitise_display_name(String.t()) :: String.t()
  def sanitise_display_name(name) when is_binary(name) do
    name
    |> String.replace(~r/[^\p{L}\p{N}\s'.\-]/u, "")
    |> String.trim()
  end
end

defmodule UserManagement.ProfileService do
  @moduledoc """
  Manages user profile creation, handle generation, and profile updates.
  Integrates with the account repository to persist profile data.
  """

  require UserManagement.StringHelpers

  alias UserManagement.StringHelpers

  @handle_max_length 30

  @doc """
  Generates a unique handle candidate from a display name.
  The handle is slugified, trimmed to the max length, and deduped if needed.
  """
  @spec generate_handle(String.t(), list(String.t())) :: String.t()
  def generate_handle(display_name, existing_handles) do
    base_handle =
      display_name
      |> StringHelpers.slugify()
      |> String.slice(0, @handle_max_length)

    if base_handle not in existing_handles do
      base_handle
    else
      Enum.find_value(1..100, base_handle, fn suffix ->
        candidate = "#{base_handle}-#{suffix}"

        if candidate not in existing_handles, do: candidate
      end)
    end
  end

  @doc """
  Creates a new user profile from registration data.
  """
  @spec create_profile(map(), list(String.t())) :: {:ok, map()} | {:error, String.t()}
  def create_profile(%{display_name: display_name, email: email, bio: bio}, existing_handles) do
    sanitised_name = StringHelpers.sanitise_display_name(display_name)

    if String.length(sanitised_name) < 2 do
      {:error, "Display name is too short after sanitisation"}
    else
      handle = generate_handle(sanitised_name, existing_handles)

      {:ok,
       %{
         display_name: sanitised_name,
         handle: handle,
         initials: StringHelpers.initials(sanitised_name),
         email: email,
         bio: String.slice(bio || "", 0, 300),
         created_at: DateTime.utc_now()
       }}
    end
  end

  @doc """
  Updates the display name on an existing profile.
  """
  @spec update_display_name(map(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def update_display_name(profile, new_name) do
    sanitised = StringHelpers.sanitise_display_name(new_name)

    if String.length(sanitised) < 2 do
      {:error, "Display name is too short"}
    else
      {:ok, %{profile | display_name: sanitised, initials: StringHelpers.initials(sanitised)}}
    end
  end
end
```
