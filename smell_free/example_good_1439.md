```elixir
defmodule Notifications.PreferenceResolver do
  @moduledoc """
  Resolves the effective notification delivery preferences for a user
  by merging account-level defaults, user overrides, and per-notification-type
  settings. Returns the definitive channel list for any given event type.
  """

  alias Notifications.{Repo, UserPreference, AccountDefault}

  @type channel :: :email | :sms | :push | :in_app
  @type event_type :: atom()
  @type user_id :: String.t()
  @type account_id :: String.t()

  @type resolved_preference :: %{
          channels: [channel()],
          muted: boolean(),
          digest_mode: boolean(),
          digest_frequency: :immediate | :hourly | :daily | :weekly
        }

  @all_channels [:email, :sms, :push, :in_app]

  @spec resolve(user_id(), account_id(), event_type()) :: resolved_preference()
  def resolve(user_id, account_id, event_type)
      when is_binary(user_id) and is_binary(account_id) and is_atom(event_type) do
    account_defaults = load_account_defaults(account_id, event_type)
    user_prefs = load_user_preferences(user_id, event_type)

    merge_preferences(account_defaults, user_prefs)
  end

  @spec muted?(user_id(), account_id(), event_type()) :: boolean()
  def muted?(user_id, account_id, event_type) do
    resolve(user_id, account_id, event_type).muted
  end

  @spec effective_channels(user_id(), account_id(), event_type()) :: [channel()]
  def effective_channels(user_id, account_id, event_type) do
    resolve(user_id, account_id, event_type).channels
  end

  @spec update_preference(user_id(), event_type(), map()) ::
          {:ok, UserPreference.t()} | {:error, Ecto.Changeset.t()}
  def update_preference(user_id, event_type, params)
      when is_binary(user_id) and is_atom(event_type) do
    existing = Repo.get_by(UserPreference, user_id: user_id, event_type: to_string(event_type))

    changeset_params = Map.put(params, :event_type, to_string(event_type))

    case existing do
      nil ->
        %UserPreference{}
        |> UserPreference.creation_changeset(Map.put(changeset_params, :user_id, user_id))
        |> Repo.insert()

      pref ->
        pref |> UserPreference.update_changeset(changeset_params) |> Repo.update()
    end
  end

  @spec load_account_defaults(account_id(), event_type()) :: map()
  defp load_account_defaults(account_id, event_type) do
    case Repo.get_by(AccountDefault, account_id: account_id, event_type: to_string(event_type)) do
      nil -> default_preference()
      record -> to_preference_map(record)
    end
  end

  @spec load_user_preferences(user_id(), event_type()) :: map() | nil
  defp load_user_preferences(user_id, event_type) do
    case Repo.get_by(UserPreference, user_id: user_id, event_type: to_string(event_type)) do
      nil -> nil
      record -> to_preference_map(record)
    end
  end

  @spec merge_preferences(map(), map() | nil) :: resolved_preference()
  defp merge_preferences(account_defaults, nil), do: account_defaults

  defp merge_preferences(account_defaults, user_prefs) do
    channels =
      case user_prefs.channels do
        [] -> account_defaults.channels
        user_channels -> filter_allowed_channels(user_channels, account_defaults.channels)
      end

    %{
      channels: channels,
      muted: user_prefs.muted,
      digest_mode: Map.get(user_prefs, :digest_mode, account_defaults.digest_mode),
      digest_frequency: Map.get(user_prefs, :digest_frequency, account_defaults.digest_frequency)
    }
  end

  @spec filter_allowed_channels([channel()], [channel()]) :: [channel()]
  defp filter_allowed_channels(requested, allowed) do
    Enum.filter(requested, &(&1 in allowed))
  end

  @spec default_preference() :: resolved_preference()
  defp default_preference do
    %{
      channels: [:email, :in_app],
      muted: false,
      digest_mode: false,
      digest_frequency: :immediate
    }
  end

  @spec to_preference_map(struct()) :: map()
  defp to_preference_map(record) do
    %{
      channels: Enum.map(record.channels, &String.to_existing_atom/1),
      muted: record.muted,
      digest_mode: record.digest_mode,
      digest_frequency: String.to_existing_atom(record.digest_frequency)
    }
  end
end
```
