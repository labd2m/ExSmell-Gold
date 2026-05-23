# Annotated Example 19 — Long Parameter List

## Metadata

| Field | Value |
|---|---|
| **Smell name** | Long Parameter List |
| **Expected smell location** | `Accounts.Profiles.update_profile/9` |
| **Affected function(s)** | `update_profile/9` |
| **Explanation** | The function accepts 9 individual parameters for updating a user profile: identity (user_id), personal data (first_name, last_name, phone, birth_date), preferences (locale, timezone), and UI settings (avatar_url, bio). These clearly belong in a `%ProfileUpdate{}` changeset map rather than being passed as nine separate positional arguments. |

---

```elixir
# VALIDATION: SMELL START - Long Parameter List
# VALIDATION: This is a smell because `update_profile/9` takes nine individual
# parameters to represent what is conceptually a single "profile update" data
# object. The mix of personal info (first_name, last_name, phone, birth_date),
# locale preferences (locale, timezone), and profile content (avatar_url, bio)
# should be encapsulated in a single map or struct passed as one argument,
# both for clarity and to avoid incorrect argument ordering at call sites.
defmodule Accounts.Profiles do
  @moduledoc """
  Manages user profile information, preferences, and avatars.
  """

  require Logger

  alias Accounts.Repo
  alias Accounts.Schemas.UserProfile
  alias Accounts.Schemas.AuditEvent
  alias Accounts.AvatarStore

  @valid_locales ~w(en pt es fr de ja)
  @valid_timezones ~w(UTC America/New_York America/Sao_Paulo Europe/London Europe/Berlin Asia/Tokyo)
  @max_bio_length 500

  def update_profile(
        user_id,
        first_name,
        last_name,
        phone,
        birth_date,
        locale,
        timezone,
        avatar_url,
        bio
      ) do
# VALIDATION: SMELL END
    profile = Repo.get_by!(UserProfile, user_id: user_id)

    with :ok <- validate_name(first_name, :first_name),
         :ok <- validate_name(last_name, :last_name),
         :ok <- maybe_validate_phone(phone),
         :ok <- maybe_validate_birth_date(birth_date),
         :ok <- validate_locale(locale),
         :ok <- validate_timezone(timezone),
         :ok <- maybe_validate_avatar(avatar_url),
         :ok <- validate_bio(bio) do
      update_attrs = %{
        first_name: String.trim(first_name),
        last_name: String.trim(last_name),
        phone: phone,
        birth_date: birth_date,
        locale: locale,
        timezone: timezone,
        avatar_url: avatar_url,
        bio: bio,
        updated_at: DateTime.utc_now()
      }

      case Repo.update(UserProfile.changeset(profile, update_attrs)) do
        {:ok, updated} ->
          audit_attrs = %{
            user_id: user_id,
            action: :profile_updated,
            metadata: %{fields_changed: Map.keys(update_attrs)},
            inserted_at: DateTime.utc_now()
          }

          Repo.insert(AuditEvent.changeset(%AuditEvent{}, audit_attrs))
          Logger.info("Profile updated for user #{user_id}")
          {:ok, updated}

        {:error, changeset} ->
          Logger.error("Profile update failed for #{user_id}: #{inspect(changeset.errors)}")
          {:error, :update_failed}
      end
    end
  end

  defp validate_name(name, field) do
    if is_binary(name) and String.length(String.trim(name)) >= 1 do
      :ok
    else
      {:error, {field, :blank}}
    end
  end

  defp maybe_validate_phone(nil), do: :ok

  defp maybe_validate_phone(phone) do
    if Regex.match?(~r/^\+?[1-9]\d{6,14}$/, phone) do
      :ok
    else
      {:error, :invalid_phone}
    end
  end

  defp maybe_validate_birth_date(nil), do: :ok

  defp maybe_validate_birth_date(date) do
    case Date.from_iso8601(date) do
      {:ok, _} -> :ok
      _ -> {:error, :invalid_birth_date}
    end
  end

  defp validate_locale(l) when l in @valid_locales, do: :ok
  defp validate_locale(l), do: {:error, {:unsupported_locale, l}}

  defp validate_timezone(tz) when tz in @valid_timezones, do: :ok
  defp validate_timezone(tz), do: {:error, {:unknown_timezone, tz}}

  defp maybe_validate_avatar(nil), do: :ok

  defp maybe_validate_avatar(url) do
    if AvatarStore.valid_url?(url), do: :ok, else: {:error, :invalid_avatar_url}
  end

  defp validate_bio(nil), do: :ok

  defp validate_bio(bio) when is_binary(bio) do
    if String.length(bio) <= @max_bio_length, do: :ok, else: {:error, :bio_too_long}
  end
end
```
