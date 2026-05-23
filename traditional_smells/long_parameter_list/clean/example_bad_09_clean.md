```elixir
defmodule UserManagement.Profiles do
  @moduledoc """
  Manages user profile data including personal details, contact info, and account preferences.
  """

  require Logger

  alias UserManagement.{Profile, AvatarUploader, AuditTrail, Repo}

  @allowed_visibility [:public, :private, :contacts_only]
  @max_bio_length 500

  def update_profile(
        user_id,
        first_name,
        last_name,
        date_of_birth,
        gender,
        bio,
        website_url,
        location,
        phone_number,
        avatar_url,
        profile_visibility,
        receive_marketing_emails,
        two_factor_enabled
      ) do

    with :ok <- validate_user_exists(user_id),
         :ok <- validate_names(first_name, last_name),
         :ok <- validate_bio(bio),
         :ok <- validate_visibility(profile_visibility),
         :ok <- validate_url(website_url) do

      avatar_path =
        if avatar_url do
          case AvatarUploader.store(user_id, avatar_url) do
            {:ok, path} -> path
            {:error, _} -> nil
          end
        end

      changes = %{
        first_name: String.trim(first_name),
        last_name: String.trim(last_name),
        date_of_birth: date_of_birth,
        gender: gender,
        bio: bio,
        website_url: website_url,
        location: location,
        phone_number: phone_number,
        avatar_path: avatar_path,
        profile_visibility: profile_visibility,
        receive_marketing_emails: receive_marketing_emails,
        two_factor_enabled: two_factor_enabled,
        updated_at: DateTime.utc_now()
      }

      case Repo.update(user_id, changes) do
        {:ok, updated_profile} ->
          AuditTrail.log(user_id, :profile_updated, %{fields_changed: Map.keys(changes)})
          Logger.info("Profile updated for user #{user_id}")
          {:ok, updated_profile}

        {:error, reason} ->
          Logger.error("Failed to update profile for user #{user_id}: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  def fetch_profile(user_id) do
    case Repo.get(Profile, user_id) do
      nil -> {:error, :not_found}
      profile -> {:ok, profile}
    end
  end

  def deactivate(user_id) do
    case Repo.update(user_id, %{status: :deactivated, deactivated_at: DateTime.utc_now()}) do
      {:ok, _} ->
        AuditTrail.log(user_id, :profile_deactivated, %{})
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_user_exists(user_id) do
    case Repo.get(Profile, user_id) do
      nil -> {:error, :user_not_found}
      _ -> :ok
    end
  end

  defp validate_names(first, last)
       when is_binary(first) and byte_size(first) > 0 and
              is_binary(last) and byte_size(last) > 0,
       do: :ok

  defp validate_names(_, _), do: {:error, :invalid_name}

  defp validate_bio(nil), do: :ok

  defp validate_bio(bio) when is_binary(bio) do
    if String.length(bio) <= @max_bio_length, do: :ok, else: {:error, :bio_too_long}
  end

  defp validate_bio(_), do: {:error, :invalid_bio}

  defp validate_visibility(v) when v in @allowed_visibility, do: :ok
  defp validate_visibility(v), do: {:error, {:invalid_visibility, v}}

  defp validate_url(nil), do: :ok

  defp validate_url(url) when is_binary(url) do
    if String.starts_with?(url, ["http://", "https://"]), do: :ok, else: {:error, :invalid_url}
  end

  defp validate_url(_), do: {:error, :invalid_url}
end
```
