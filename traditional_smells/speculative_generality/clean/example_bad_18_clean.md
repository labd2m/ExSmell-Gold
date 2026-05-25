```elixir
defmodule UserManagement.ProfileManager do
  @moduledoc """
  Manages user profile data including contact information, preferences,
  avatar, and account metadata. Maintains a change history for auditing
  and compliance purposes.
  """

  alias UserManagement.{User, ProfileAudit, AvatarStore, Repo}
  alias Notifications.Mailer

  @allowed_fields    [:name, :phone, :timezone, :locale, :bio]
  @preference_fields [:email_notifications, :sms_notifications, :marketing_opt_in]

  def update_profile(user_id, attrs, audit_level \\ :standard) do
    user          = Repo.get!(User, user_id)
    allowed       = Map.take(attrs, @allowed_fields)
    old_values    = Map.take(user, Map.keys(allowed))

    case User.changeset(user, allowed) |> Repo.update() do
      {:ok, updated_user} ->
        record_audit(user_id, old_values, allowed, audit_level)
        {:ok, updated_user}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def update_contact_info(user_id, contact_attrs) do
    allowed = Map.take(contact_attrs, [:name, :phone])
    update_profile(user_id, allowed)
  end

  def update_preferences(user_id, pref_attrs) do
    allowed = Map.take(pref_attrs, @preference_fields)
    update_profile(user_id, allowed)
  end

  def update_avatar(user_id, image_data) do
    case AvatarStore.upload(user_id, image_data) do
      {:ok, avatar_url} ->
        update_profile(user_id, %{avatar_url: avatar_url})

      {:error, reason} ->
        {:error, reason}
    end
  end

  def change_email(user_id, new_email, current_password) do
    user = Repo.get!(User, user_id)

    with :ok <- verify_password(user, current_password),
         :ok <- validate_email_unique(new_email) do
      case User.changeset(user, %{email: new_email, email_verified: false}) |> Repo.update() do
        {:ok, updated} ->
          Mailer.send_email_change_verification(new_email, updated.verification_token)
          {:ok, updated}

        {:error, cs} ->
          {:error, cs}
      end
    end
  end

  def deactivate_profile(user_id, reason) do
    user = Repo.get!(User, user_id)

    user
    |> User.changeset(%{
      status:              :deactivated,
      deactivation_reason: reason,
      deactivated_at:      DateTime.utc_now()
    })
    |> Repo.update()
  end

  def profile_audit_trail(user_id, limit \\ 50) do
    ProfileAudit
    |> Repo.all()
    |> Enum.filter(&(&1.user_id == user_id))
    |> Enum.sort_by(& &1.occurred_at, {:desc, DateTime})
    |> Enum.take(limit)
  end

  def get_profile(user_id) do
    case Repo.get(User, user_id) do
      nil  -> {:error, :not_found}
      user -> {:ok, Map.drop(user, [:hashed_password, :verification_token])}
    end
  end

  def search_users(query_string) do
    User
    |> Repo.all()
    |> Enum.filter(fn user ->
      String.contains?(String.downcase(user.name || ""), String.downcase(query_string)) or
        String.contains?(String.downcase(user.email), String.downcase(query_string))
    end)
    |> Enum.take(25)
  end


  defp record_audit(user_id, old_values, new_values, _audit_level) do
    Repo.insert!(%ProfileAudit{
      user_id:      user_id,
      changed_keys: Map.keys(new_values),
      old_snapshot: old_values,
      new_snapshot: new_values,
      occurred_at:  DateTime.utc_now()
    })
  end

  defp verify_password(user, password) do
    if Bcrypt.verify_pass(password, user.hashed_password) do
      :ok
    else
      {:error, :invalid_password}
    end
  end

  defp validate_email_unique(email) do
    case Repo.get_by(User, email: email) do
      nil -> :ok
      _   -> {:error, :email_already_taken}
    end
  end
end
```
