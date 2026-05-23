```elixir
defmodule Accounts.UserProfile do
  @moduledoc "Represents a user's public-facing profile."

  defstruct [
    :id,
    :user_id,
    :first_name,
    :last_name,
    :avatar_url,
    :bio,
    :phone,
    :email_verified,
    :phone_verified,
    :marketing_consent,
    :linked_providers,
    :locale,
    :updated_at
  ]

  def get!(id) do
    %__MODULE__{
      id: id,
      user_id: "USR-210",
      first_name: "Maria",
      last_name: "Santos",
      avatar_url: "https://cdn.example.com/avatars/maria.jpg",
      bio: "Product Manager at Example Corp.",
      phone: "+1-555-0190",
      email_verified: true,
      phone_verified: false,
      marketing_consent: true,
      linked_providers: [:google, :github],
      locale: "pt-BR",
      updated_at: ~U[2024-03-10 09:00:00Z]
    }
  end

  def full_name(%__MODULE__{first_name: f, last_name: l}), do: "#{f} #{l}"

  def has_avatar?(%__MODULE__{avatar_url: nil}), do: false
  def has_avatar?(_), do: true

  def marketing_opted_in?(%__MODULE__{marketing_consent: true}), do: true
  def marketing_opted_in?(_), do: false

  def verified?(%__MODULE__{email_verified: true}), do: true
  def verified?(_), do: false

  def linked_providers(%__MODULE__{linked_providers: providers}), do: providers

  def locale_display(%__MODULE__{locale: l}), do: l
end

defmodule Accounts.LegacyProfile do
  @moduledoc "Snapshot of a user profile in the legacy system."

  defstruct [:user_id, :display_name, :has_picture, :subscribed_to_marketing, :is_verified, :sso_providers]

  def get_by_user(user_id) do
    %__MODULE__{
      user_id: user_id,
      display_name: "Maria S.",
      has_picture: true,
      subscribed_to_marketing: false,
      is_verified: true,
      sso_providers: [:google]
    }
  end
end

defmodule Accounts.ProfileMigrator do
  @moduledoc """
  Handles migrating user profiles from the legacy system to the new schema,
  computing diffs and applying necessary updates.
  """

  alias Accounts.{UserProfile, LegacyProfile}
  require Logger

  @doc """
  Runs a migration diff for the given profile ID and logs fields that
  have changed since the legacy snapshot.
  """
  def migrate(profile_id) do
    diff = build_migration_diff(profile_id)

    if map_size(diff.changes) == 0 do
      Logger.info("Profile #{profile_id}: no changes detected, skipping migration.")
      {:ok, :no_op}
    else
      Logger.info("Profile #{profile_id}: #{map_size(diff.changes)} field(s) changed.")
      apply_changes(profile_id, diff.changes)
    end
  end

  defp apply_changes(profile_id, changes) do
    Logger.debug("Applying #{inspect(changes)} to profile #{profile_id}")
    {:ok, :migrated}
  end

  defp build_migration_diff(profile_id) do
    profile  = UserProfile.get!(profile_id)
    legacy   = LegacyProfile.get_by_user(profile.user_id)

    changes = %{}

    changes =
      if UserProfile.full_name(profile) != legacy.display_name do
        Map.put(changes, :display_name, UserProfile.full_name(profile))
      else
        changes
      end

    changes =
      if UserProfile.has_avatar?(profile) != legacy.has_picture do
        Map.put(changes, :has_picture, UserProfile.has_avatar?(profile))
      else
        changes
      end

    changes =
      if UserProfile.marketing_opted_in?(profile) != legacy.subscribed_to_marketing do
        Map.put(changes, :subscribed_to_marketing, UserProfile.marketing_opted_in?(profile))
      else
        changes
      end

    changes =
      if UserProfile.verified?(profile) != legacy.is_verified do
        Map.put(changes, :is_verified, UserProfile.verified?(profile))
      else
        changes
      end

    changes =
      if UserProfile.linked_providers(profile) != legacy.sso_providers do
        Map.put(changes, :sso_providers, UserProfile.linked_providers(profile))
      else
        changes
      end

    %{profile_id: profile_id, changes: changes}
  end
end
```
