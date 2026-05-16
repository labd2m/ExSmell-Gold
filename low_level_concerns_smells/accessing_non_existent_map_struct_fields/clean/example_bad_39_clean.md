```elixir
defmodule UserManagement.ProfileUpdater do
  @moduledoc """
  Applies validated profile changes to user records.
  Handles display preferences, avatar management,
  locale settings, and notification configuration.
  """

  require Logger

  @supported_locales ~w(en es fr pt de ja zh)
  @valid_frequencies [:realtime, :daily, :weekly, :never]
  @avatar_max_bytes 2_097_152

  @type user :: %{
          id: String.t(),
          email: String.t(),
          display_name: String.t(),
          locale: String.t(),
          avatar_url: String.t() | nil,
          notification_frequency: atom(),
          updated_at: DateTime.t()
        }

  @type changeset :: %{
          optional(:display_name) => String.t(),
          optional(:locale) => String.t(),
          optional(:avatar_url) => String.t(),
          optional(:notification_frequency) => atom(),
          optional(:bio) => String.t()
        }

  @spec apply_changes(user(), changeset()) :: {:ok, user()} | {:error, [String.t()]}
  def apply_changes(user, changeset) do
    with {:ok, validated} <- validate_changeset(changeset) do
      updated = merge_changes(user, validated)
      Logger.info("Profile updated for user=#{user.id}")
      {:ok, updated}
    end
  end

  defp validate_changeset(changeset) do
    errors =
      []
      |> check_display_name(changeset)
      |> check_locale(changeset)
      |> check_notification_frequency(changeset)

    if errors == [], do: {:ok, changeset}, else: {:error, Enum.reverse(errors)}
  end

  defp check_display_name(errors, changeset) do
    case changeset[:display_name] do
      nil  -> errors
      ""   -> ["display_name cannot be blank" | errors]
      name ->
        if String.length(name) > 80,
          do: ["display_name exceeds 80 characters" | errors],
          else: errors
    end
  end

  defp check_locale(errors, changeset) do
    case changeset[:locale] do
      nil    -> errors
      locale ->
        if locale in @supported_locales,
          do: errors,
          else: ["unsupported locale: #{locale}" | errors]
    end
  end

  defp check_notification_frequency(errors, changeset) do
    case changeset[:notification_frequency] do
      nil  -> errors
      freq ->
        if freq in @valid_frequencies,
          do: errors,
          else: ["invalid notification_frequency: #{freq}" | errors]
    end
  end

  defp merge_changes(user, changeset) do
    new_avatar_url            = changeset[:avatar_url]
    new_locale                = changeset[:locale]
    new_notification_frequency = changeset[:notification_frequency]

    %{user |
      display_name:           Map.get(changeset, :display_name, user.display_name),
      avatar_url:             new_avatar_url || user.avatar_url,
      locale:                 new_locale || user.locale,
      notification_frequency: new_notification_frequency || user.notification_frequency,
      updated_at:             DateTime.utc_now()
    }
    |> maybe_update_bio(changeset)
  end

  defp maybe_update_bio(user, changeset) do
    case changeset[:bio] do
      nil -> user
      bio -> Map.put(user, :bio, bio)
    end
  end

  @spec reset_avatar(user()) :: {:ok, user()}
  def reset_avatar(user) do
    updated = %{user | avatar_url: nil, updated_at: DateTime.utc_now()}
    Logger.info("Avatar reset for user=#{user.id}")
    {:ok, updated}
  end

  @spec deactivate(user(), String.t()) :: {:ok, user()}
  def deactivate(user, reason) do
    updated =
      user
      |> Map.put(:active, false)
      |> Map.put(:deactivated_at, DateTime.utc_now())
      |> Map.put(:deactivation_reason, reason)

    Logger.info("User #{user.id} deactivated: #{reason}")
    {:ok, updated}
  end
end
```
