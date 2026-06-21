```elixir
defmodule Accounts.NotificationPreferences do
  @moduledoc """
  Context for managing per-user notification channel preferences.

  Each user can independently enable or disable notification channels
  (email, SMS, push, webhook) per event category. The default set of
  preferences is provisioned on first access.
  """

  import Ecto.Query, only: [from: 2]
  alias Ecto.Multi
  alias Accounts.{Repo, NotificationPreference}

  @type user_id :: pos_integer()
  @type channel :: :email | :sms | :push | :webhook
  @type category :: :security | :billing | :marketing | :product_updates | :system
  @type preference_key :: {channel(), category()}

  @channels [:email, :sms, :push, :webhook]
  @categories [:security, :billing, :marketing, :product_updates, :system]

  @opt_in_by_default [
    {:email, :security},
    {:email, :billing},
    {:push, :security}
  ]

  @doc """
  Returns all notification preferences for `user_id`, creating defaults
  on first call.
  """
  @spec get_all(user_id()) :: [NotificationPreference.t()]
  def get_all(user_id) when is_integer(user_id) and user_id > 0 do
    existing = load_preferences(user_id)

    if needs_provisioning?(existing) do
      provision_defaults(user_id)
      load_preferences(user_id)
    else
      existing
    end
  end

  @doc """
  Returns `true` if the user has enabled notifications for the given
  channel and category combination.
  """
  @spec enabled?(user_id(), channel(), category()) :: boolean()
  def enabled?(user_id, channel, category)
      when channel in @channels and category in @categories do
    from(p in NotificationPreference,
      where:
        p.user_id == ^user_id and
          p.channel == ^channel and
          p.category == ^category and
          p.enabled == true
    )
    |> Repo.exists?()
  end

  @doc """
  Updates a single preference entry for the given user, channel, and category.
  """
  @spec set(user_id(), channel(), category(), boolean()) ::
          {:ok, NotificationPreference.t()} | {:error, Ecto.Changeset.t()}
  def set(user_id, channel, category, enabled)
      when is_boolean(enabled) and channel in @channels and category in @categories do
    attrs = %{user_id: user_id, channel: channel, category: category, enabled: enabled}

    %NotificationPreference{}
    |> NotificationPreference.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:enabled, :updated_at]},
      conflict_target: [:user_id, :channel, :category]
    )
  end

  @doc "Disables all marketing communications for a user across all channels."
  @spec unsubscribe_marketing(user_id()) :: :ok
  def unsubscribe_marketing(user_id) when is_integer(user_id) do
    from(p in NotificationPreference,
      where: p.user_id == ^user_id and p.category == :marketing
    )
    |> Repo.update_all(set: [enabled: false, updated_at: DateTime.utc_now()])

    :ok
  end

  defp load_preferences(user_id) do
    from(p in NotificationPreference,
      where: p.user_id == ^user_id,
      order_by: [asc: p.channel, asc: p.category]
    )
    |> Repo.all()
  end

  defp needs_provisioning?(preferences) do
    expected_count = length(@channels) * length(@categories)
    length(preferences) < expected_count
  end

  defp provision_defaults(user_id) do
    all_combinations = for channel <- @channels, category <- @categories, do: {channel, category}

    Multi.new()
    |> insert_all_preferences(user_id, all_combinations)
    |> Repo.transaction()
  end

  defp insert_all_preferences(multi, user_id, combinations) do
    Enum.reduce(combinations, multi, fn {channel, category}, acc ->
      enabled = {channel, category} in @opt_in_by_default
      attrs = %{user_id: user_id, channel: channel, category: category, enabled: enabled}
      changeset = NotificationPreference.changeset(%NotificationPreference{}, attrs)
      Multi.insert(acc, {channel, category}, changeset, on_conflict: :nothing, conflict_target: [:user_id, :channel, :category])
    end)
  end
end
```
