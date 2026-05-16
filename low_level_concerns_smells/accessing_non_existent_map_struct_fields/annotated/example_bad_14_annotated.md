# Annotated Example 14

## Metadata

- **Smell name:** Accessing non-existent Map/Struct fields
- **Expected smell location:** `UserManagement.ProfileUpdater.update/2`, lines where `changes` map keys are accessed dynamically
- **Affected function(s):** `update/2`
- **Short explanation:** `changes[:email]`, `changes[:phone]`, `changes[:display_name]`, and `changes[:avatar_url]` use dynamic bracket access on a plain map. When `:email` is absent the silent `nil` passes validation checks that only guard against malformed values, silently clearing a required field instead of rejecting the update.

---

```elixir
defmodule UserManagement.ProfileUpdater do
  @moduledoc """
  Applies partial updates to user profiles, validates field-level
  constraints, and emits change-log events for auditing.
  """

  require Logger

  @email_regex    ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/
  @phone_regex    ~r/^\+?[0-9\s\-().]{7,20}$/
  @max_name_len   80
  @max_url_len    512

  @type profile :: %{
          id: String.t(),
          email: String.t(),
          phone: String.t() | nil,
          display_name: String.t(),
          avatar_url: String.t() | nil,
          updated_at: DateTime.t()
        }

  @spec update(profile(), map()) :: {:ok, profile()} | {:error, list(String.t())}
  def update(%{} = profile, changes) do
    # VALIDATION: SMELL START - Accessing non-existent Map/Struct fields
    # VALIDATION: This is a smell because `changes[:email]`,
    # `changes[:phone]`, `changes[:display_name]`, and `changes[:avatar_url]`
    # use dynamic bracket access. A missing `:email` key silently returns
    # `nil`, which then passes the `is_nil` guard inside `validate_email/1`
    # and gets written into the profile as `nil`, clearing a required field
    # without any error. The caller cannot distinguish "email intentionally
    # set to nil" from "email key was not supplied at all".
    email        = changes[:email]
    phone        = changes[:phone]
    display_name = changes[:display_name]
    avatar_url   = changes[:avatar_url]
    # VALIDATION: SMELL END

    errors =
      []
      |> maybe_validate_email(email)
      |> maybe_validate_phone(phone)
      |> maybe_validate_display_name(display_name)
      |> maybe_validate_avatar_url(avatar_url)

    if errors == [] do
      updated =
        profile
        |> maybe_put(:email, email)
        |> maybe_put(:phone, phone)
        |> maybe_put(:display_name, display_name)
        |> maybe_put(:avatar_url, avatar_url)
        |> Map.put(:updated_at, DateTime.utc_now())

      emit_change_log(profile, updated)
      {:ok, updated}
    else
      {:error, errors}
    end
  end

  # ── Validators ──────────────────────────────────────────────────────────────

  defp maybe_validate_email(errors, nil), do: errors

  defp maybe_validate_email(errors, email) do
    if Regex.match?(@email_regex, email) do
      errors
    else
      ["Invalid email address: #{email}" | errors]
    end
  end

  defp maybe_validate_phone(errors, nil), do: errors

  defp maybe_validate_phone(errors, phone) do
    if Regex.match?(@phone_regex, phone) do
      errors
    else
      ["Invalid phone number: #{phone}" | errors]
    end
  end

  defp maybe_validate_display_name(errors, nil), do: errors

  defp maybe_validate_display_name(errors, name) do
    cond do
      String.trim(name) == "" ->
        ["Display name must not be blank" | errors]

      String.length(name) > @max_name_len ->
        ["Display name exceeds #{@max_name_len} characters" | errors]

      true ->
        errors
    end
  end

  defp maybe_validate_avatar_url(errors, nil), do: errors

  defp maybe_validate_avatar_url(errors, url) do
    cond do
      String.length(url) > @max_url_len ->
        ["Avatar URL exceeds #{@max_url_len} characters" | errors]

      not String.starts_with?(url, ["http://", "https://"]) ->
        ["Avatar URL must be an absolute HTTP(S) URL" | errors]

      true ->
        errors
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp emit_change_log(before, after_) do
    changed_fields =
      [:email, :phone, :display_name, :avatar_url]
      |> Enum.filter(fn field -> Map.get(before, field) != Map.get(after_, field) end)

    Logger.info("Profile updated",
      user_id: before.id,
      changed_fields: changed_fields
    )
  end
end
```
