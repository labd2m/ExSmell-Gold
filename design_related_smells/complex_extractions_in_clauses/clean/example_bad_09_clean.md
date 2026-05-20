```elixir
defmodule UserManagement.ProfileUpdater do
  @moduledoc """
  Applies profile update changesets with role-aware validation and
  audit logging. Enforces field-level permissions based on the
  acting user's role and account status.
  """

  require Logger

  alias UserManagement.{
    UserRepo,
    AuditLog,
    Notifier,
    PermissionPolicy,
    PreferenceValidator
  }

  @active_statuses [:active, :trial]

  def apply_update(
        %UserManagement.User{
          user_id: user_id,
          email: email,
          display_name: display_name,
          locale: locale,
          preferences: preferences,
          role: :admin,
          account_status: account_status
        },
        changeset
      )
      when account_status in @active_statuses do
    Logger.info("[ProfileUpdater] Admin user #{user_id} applying profile update")

    with :ok <- PermissionPolicy.check(:admin, changeset),
         {:ok, validated_prefs} <- maybe_validate_preferences(changeset, preferences),
         changeset_with_prefs <- Map.put(changeset, :preferences, validated_prefs),
         {:ok, updated_user} <- UserRepo.update(user_id, changeset_with_prefs),
         :ok <- maybe_notify_email_change(user_id, email, changeset),
         :ok <- AuditLog.write(:profile_updated, user_id, %{
                  role: :admin,
                  changed_fields: Map.keys(changeset),
                  display_name: display_name,
                  locale: locale
                }) do
      Logger.info("[ProfileUpdater] Admin profile #{user_id} updated successfully")
      {:ok, updated_user}
    else
      {:error, :permission_denied} ->
        Logger.warning("[ProfileUpdater] Admin #{user_id} attempted disallowed field update")
        {:error, :permission_denied}

      {:error, reason} ->
        Logger.error("[ProfileUpdater] Admin update failed for #{user_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def apply_update(
        %UserManagement.User{
          user_id: user_id,
          email: email,
          display_name: display_name,
          locale: locale,
          preferences: preferences,
          role: :member,
          account_status: account_status
        },
        changeset
      )
      when account_status in @active_statuses do
    Logger.info("[ProfileUpdater] Member user #{user_id} applying profile update")

    restricted_changeset = Map.drop(changeset, [:role, :account_status, :permissions])

    with :ok <- PermissionPolicy.check(:member, restricted_changeset),
         {:ok, validated_prefs} <- maybe_validate_preferences(restricted_changeset, preferences),
         final_changeset <- Map.put(restricted_changeset, :preferences, validated_prefs),
         {:ok, updated_user} <- UserRepo.update(user_id, final_changeset),
         :ok <- maybe_notify_email_change(user_id, email, restricted_changeset),
         :ok <- AuditLog.write(:profile_updated, user_id, %{
                  role: :member,
                  changed_fields: Map.keys(final_changeset),
                  display_name: display_name,
                  locale: locale
                }) do
      {:ok, updated_user}
    else
      {:error, :permission_denied} ->
        {:error, :permission_denied}

      {:error, reason} ->
        Logger.error("[ProfileUpdater] Member update failed for #{user_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def apply_update(
        %UserManagement.User{
          user_id: user_id,
          email: email,
          display_name: display_name,
          locale: locale,
          preferences: preferences,
          role: :support_agent,
          account_status: account_status
        },
        changeset
      )
      when account_status in @active_statuses do
    Logger.info("[ProfileUpdater] Support agent #{user_id} updating profile")

    allowed_fields = [:display_name, :locale, :preferences, :timezone]
    filtered_changeset = Map.take(changeset, allowed_fields)

    with :ok <- PermissionPolicy.check(:support_agent, filtered_changeset),
         {:ok, validated_prefs} <- maybe_validate_preferences(filtered_changeset, preferences),
         final_changeset <- Map.put(filtered_changeset, :preferences, validated_prefs),
         {:ok, updated_user} <- UserRepo.update(user_id, final_changeset),
         :ok <- maybe_notify_email_change(user_id, email, filtered_changeset),
         :ok <- AuditLog.write(:profile_updated, user_id, %{
                  role: :support_agent,
                  changed_fields: Map.keys(final_changeset),
                  display_name: display_name,
                  locale: locale
                }) do
      {:ok, updated_user}
    else
      {:error, reason} ->
        Logger.error("[ProfileUpdater] Support agent update failed for #{user_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def apply_update(%UserManagement.User{user_id: uid, account_status: status}, _changeset)
      when status not in @active_statuses do
    Logger.warning("[ProfileUpdater] Update rejected for inactive account #{uid} (status: #{status})")
    {:error, :account_not_active}
  end

  def apply_update(%UserManagement.User{user_id: uid, role: role}, _changeset) do
    Logger.error("[ProfileUpdater] No update policy for role '#{role}' on user #{uid}")
    {:error, :unsupported_role}
  end

  # --- Private helpers ---

  defp maybe_validate_preferences(changeset, existing_preferences) do
    case Map.get(changeset, :preferences) do
      nil -> {:ok, existing_preferences}
      new_prefs -> PreferenceValidator.validate(new_prefs)
    end
  end

  defp maybe_notify_email_change(_user_id, _old_email, changeset)
       when not is_map_key(changeset, :email),
       do: :ok

  defp maybe_notify_email_change(user_id, old_email, %{email: new_email}) do
    Notifier.send_email_change_notice(user_id, old_email, new_email)
  end
end
```
