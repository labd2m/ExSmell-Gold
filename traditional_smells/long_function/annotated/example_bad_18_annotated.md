# Annotated Example — Long Function

## Metadata

- **Smell name:** Long Function
- **Expected smell location:** `UserManagement.ProfileUpdater.update/3`
- **Affected function(s):** `update/3`
- **Short explanation:** The `update/3` function mixes ownership authorization, field-level change detection, email uniqueness re-validation, avatar upload handling, changeset building, persistence, cache invalidation, and audit trail writing all in a single function. Each responsibility is meaningful enough to extract, and the combination produces a function well beyond a comfortable size.

---

```elixir
defmodule UserManagement.ProfileUpdater do
  @moduledoc """
  Handles profile update requests, including field validation, avatar uploads,
  email re-verification triggers, and audit logging.
  """

  alias UserManagement.{User, AuditEntry, EmailVerification, Repo, Cache}
  alias Integrations.{ObjectStorage, Mailer}
  require Logger

  @allowed_fields [:full_name, :username, :bio, :phone, :timezone, :language]
  @avatar_max_bytes 2 * 1024 * 1024

  # VALIDATION: SMELL START - Long Function
  # VALIDATION: This is a smell because `update/3` performs authorization, change
  # VALIDATION: diffing, email-uniqueness checking, avatar upload, profile changeset
  # VALIDATION: application, persistence, cache busting, email re-verification
  # VALIDATION: triggering, and audit logging all in a single, very long function.
  def update(actor_id, target_user_id, attrs) do
    Logger.info("Profile update actor=#{actor_id} target=#{target_user_id}")

    # --- Authorization: users may only update their own profile unless admin ---
    actor = Repo.get!(User, actor_id)

    if actor_id != target_user_id and actor.role != :admin do
      {:error, :unauthorized}
    else
      case Repo.get(User, target_user_id) do
        nil ->
          {:error, :user_not_found}

        %User{} = user ->
          # --- Separate avatar upload from regular fields ---
          {avatar_upload, profile_attrs} = Map.pop(attrs, :avatar)

          # --- Filter to allowed fields ---
          filtered_attrs = Map.take(profile_attrs, @allowed_fields)

          # --- Email uniqueness check if email is being changed ---
          email_change_pending =
            if new_email = Map.get(attrs, :email) do
              normalized = String.downcase(String.trim(new_email))
              if normalized == user.email do
                false
              else
                case Repo.get_by(User, email: normalized) do
                  nil -> false
                  _   -> :taken
                end
              end
            end

          if email_change_pending == :taken do
            {:error, :email_already_taken}
          else
            # --- Handle avatar upload ---
            avatar_url =
              if avatar_upload do
                if byte_size(avatar_upload.data) > @avatar_max_bytes do
                  nil  # will return error below
                else
                  ext = Path.extname(avatar_upload.filename)
                  key = "avatars/#{target_user_id}/#{:erlang.unique_integer([:positive])}#{ext}"

                  case ObjectStorage.put(key, avatar_upload.data, content_type: avatar_upload.content_type) do
                    {:ok, url} -> url
                    {:error, reason} ->
                      Logger.warning("Avatar upload failed for user #{target_user_id}: #{inspect(reason)}")
                      nil
                  end
                end
              end

            if avatar_upload && byte_size(avatar_upload.data) > @avatar_max_bytes do
              {:error, :avatar_too_large}
            else
              # --- Build final attrs ---
              final_attrs =
                filtered_attrs
                |> then(fn a -> if avatar_url, do: Map.put(a, :avatar_url, avatar_url), else: a end)
                |> then(fn a ->
                  if email_change_pending,
                    do: Map.put(a, :pending_email, String.downcase(String.trim(Map.get(attrs, :email)))),
                    else: a
                end)

              # --- Detect changes for audit ---
              changed_fields =
                Enum.filter(final_attrs, fn {k, v} ->
                  Map.get(user, k) != v
                end)
                |> Keyword.keys()

              # --- Persist changes ---
              case user |> User.changeset(final_attrs) |> Repo.update() do
                {:ok, updated_user} ->
                  # --- Bust cache ---
                  Cache.delete("user:#{target_user_id}")

                  # --- Trigger email re-verification if email changed ---
                  if email_change_pending do
                    raw_token = :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
                    Repo.insert!(%EmailVerification{
                      user_id: target_user_id,
                      new_email: updated_user.pending_email,
                      token: raw_token,
                      expires_at: DateTime.add(DateTime.utc_now(), 48 * 3600, :second)
                    })
                    Mailer.send_email_change_verification(%{
                      to: updated_user.pending_email,
                      token: raw_token
                    })
                  end

                  # --- Audit log ---
                  Repo.insert!(%AuditEntry{
                    user_id: target_user_id,
                    actor_id: actor_id,
                    action: "profile_updated",
                    metadata: %{changed_fields: changed_fields},
                    occurred_at: DateTime.utc_now()
                  })

                  Logger.info("Profile updated for user #{target_user_id}, fields=#{inspect(changed_fields)}")
                  {:ok, updated_user}

                {:error, changeset} ->
                  Logger.error("Profile update failed for #{target_user_id}: #{inspect(changeset.errors)}")
                  {:error, changeset}
              end
            end
          end
      end
    end
  end
  # VALIDATION: SMELL END
end
```
