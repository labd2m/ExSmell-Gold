```elixir
defmodule UserManagement.Profiles do
  @moduledoc """
  Handles user profile reads and updates for the member management service.
  """

  require Logger

  @max_bio_length 500
  @supported_themes ~w(light dark system)

  def update_profile(
        user_id,
        display_name,
        bio,
        avatar_url,
        website_url,
        phone_number,
        preferred_language,
        notification_email,
        notification_push,
        ui_theme
      ) do
    with :ok <- validate_user_id(user_id),
         :ok <- validate_display_name(display_name),
         :ok <- validate_bio(bio),
         :ok <- validate_url(avatar_url, :avatar_url),
         :ok <- validate_url(website_url, :website_url),
         :ok <- validate_theme(ui_theme) do
      changes = %{
        display_name: String.trim(display_name),
        bio: bio,
        avatar_url: avatar_url,
        website_url: website_url,
        phone_number: normalize_phone(phone_number),
        preferred_language: preferred_language,
        notifications: %{
          email: notification_email,
          push: notification_push
        },
        ui_theme: ui_theme,
        updated_at: DateTime.utc_now()
      }

      case apply_changes(user_id, changes) do
        {:ok, updated_profile} ->
          Logger.info("Profile updated for user #{user_id}")
          invalidate_cache(user_id)
          {:ok, updated_profile}

        {:error, :user_not_found} ->
          {:error, :not_found}

        {:error, reason} ->
          Logger.error("Profile update failed for user #{user_id}: #{inspect(reason)}")
          {:error, :update_failed}
      end
    end
  end

  defp validate_user_id(id) when is_binary(id) and byte_size(id) > 0, do: :ok
  defp validate_user_id(_), do: {:error, "user_id must be a non-empty string"}

  defp validate_display_name(name) when is_binary(name) and byte_size(name) > 0, do: :ok
  defp validate_display_name(_), do: {:error, "display_name must not be blank"}

  defp validate_bio(nil), do: :ok
  defp validate_bio(bio) when byte_size(bio) <= @max_bio_length, do: :ok
  defp validate_bio(_), do: {:error, "bio exceeds #{@max_bio_length} characters"}

  defp validate_url(nil, _field), do: :ok
  defp validate_url(url, field) do
    if Regex.match?(~r/^https?:\/\/.+/, url),
      do: :ok,
      else: {:error, "#{field} must be a valid URL"}
  end

  defp validate_theme(t) when t in @supported_themes, do: :ok
  defp validate_theme(t), do: {:error, "unsupported theme: #{t}"}

  defp normalize_phone(nil), do: nil
  defp normalize_phone(phone), do: String.replace(phone, ~r/\D/, "")

  defp apply_changes(user_id, changes) do
    Logger.debug("Applying profile changes for user #{user_id}: #{inspect(Map.keys(changes))}")
    {:ok, Map.put(changes, :user_id, user_id)}
  end

  defp invalidate_cache(user_id) do
    Logger.debug("Cache invalidated for user #{user_id}")
    :ok
  end
end
```
