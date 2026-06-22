```elixir
defmodule Notifications.PreferenceManager do
  @moduledoc """
  Manages per-user, per-event-type notification preferences across multiple
  delivery channels. Preferences are stored in a single JSONB column as a
  typed embedded schema, supporting heterogeneous channel configurations
  (e.g. email throttling, SMS quiet hours, push badge counts) without
  requiring a separate column per channel per event type.
  """

  alias Notifications.{PreferenceSet, Repo, UserPreference}
  import Ecto.Query

  require Logger

  @type user_id :: binary()
  @type event_type :: binary()
  @type channel :: :email | :sms | :push | :slack

  @default_preferences %{
    email: %{enabled: true, throttle_minutes: 0, digest_mode: false},
    sms: %{enabled: false, quiet_hours_start: nil, quiet_hours_end: nil},
    push: %{enabled: true, badge: true, sound: true},
    slack: %{enabled: false, channel: nil}
  }

  @doc """
  Returns the preference set for `user_id` and `event_type`, falling back
  to defaults for any channel not explicitly configured.
  """
  @spec get(user_id(), event_type()) :: map()
  def get(user_id, event_type) when is_binary(user_id) and is_binary(event_type) do
    case Repo.get_by(UserPreference, user_id: user_id, event_type: event_type) do
      nil -> @default_preferences
      %UserPreference{preferences: prefs} -> deep_merge(@default_preferences, atomise_keys(prefs))
    end
  end

  @doc """
  Returns `true` when the user has enabled `channel` for `event_type`.
  Uses quiet-hours logic for SMS to suppress notifications outside the
  user's configured active window.
  """
  @spec channel_enabled?(user_id(), event_type(), channel()) :: boolean()
  def channel_enabled?(user_id, event_type, channel) when channel in [:email, :sms, :push, :slack] do
    prefs = get(user_id, event_type)
    channel_prefs = Map.get(prefs, channel, %{})

    base_enabled = Map.get(channel_prefs, :enabled, false)

    if base_enabled and channel == :sms do
      not in_quiet_hours?(channel_prefs)
    else
      base_enabled
    end
  end

  @doc """
  Updates the preference for `user_id`, `event_type`, and `channel`.
  Merges the new values into any existing preferences, preserving other
  channel settings. Returns `{:ok, preference}` or `{:error, reason}`.
  """
  @spec update(user_id(), event_type(), channel(), map()) ::
          {:ok, UserPreference.t()} | {:error, term()}
  def update(user_id, event_type, channel, channel_prefs)
      when is_binary(user_id) and is_binary(event_type) and
             channel in [:email, :sms, :push, :slack] and is_map(channel_prefs) do
    existing = Repo.get_by(UserPreference, user_id: user_id, event_type: event_type)
    record = existing || %UserPreference{user_id: user_id, event_type: event_type}

    current_prefs = if existing, do: atomise_keys(record.preferences), else: @default_preferences
    updated_channel = Map.merge(Map.get(current_prefs, channel, %{}), channel_prefs)
    new_prefs = Map.put(current_prefs, channel, updated_channel)

    record
    |> UserPreference.changeset(%{preferences: stringify_keys(new_prefs)})
    |> Repo.insert_or_update()
  end

  @doc """
  Resets all preferences for `user_id` and `event_type` to defaults.
  """
  @spec reset(user_id(), event_type()) :: :ok
  def reset(user_id, event_type) when is_binary(user_id) and is_binary(event_type) do
    Repo.delete_all(
      from(p in UserPreference,
        where: p.user_id == ^user_id and p.event_type == ^event_type
      )
    )

    :ok
  end

  @doc """
  Returns a summary of enabled channels for every event type for `user_id`.
  Useful for rendering settings overview pages.
  """
  @spec summary(user_id()) :: [%{event_type: binary(), enabled_channels: [channel()]}]
  def summary(user_id) when is_binary(user_id) do
    UserPreference
    |> where([p], p.user_id == ^user_id)
    |> Repo.all()
    |> Enum.map(fn pref ->
      prefs = deep_merge(@default_preferences, atomise_keys(pref.preferences))

      enabled =
        [:email, :sms, :push, :slack]
        |> Enum.filter(fn ch ->
          get_in(prefs, [ch, :enabled]) == true
        end)

      %{event_type: pref.event_type, enabled_channels: enabled}
    end)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp in_quiet_hours?(%{quiet_hours_start: nil}), do: false
  defp in_quiet_hours?(%{quiet_hours_end: nil}), do: false

  defp in_quiet_hours?(%{quiet_hours_start: start_h, quiet_hours_end: end_h}) do
    %{hour: current_h} = DateTime.utc_now()

    if start_h <= end_h do
      current_h >= start_h and current_h < end_h
    else
      current_h >= start_h or current_h < end_h
    end
  end

  defp deep_merge(base, override) when is_map(base) and is_map(override) do
    Map.merge(base, override, fn _k, v1, v2 ->
      if is_map(v1) and is_map(v2), do: deep_merge(v1, v2), else: v2
    end)
  end

  defp atomise_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      atom_key = if is_binary(k), do: String.to_existing_atom(k), else: k
      value = if is_map(v), do: atomise_keys(v), else: v
      {atom_key, value}
    end)
  rescue
    _ -> map
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      str_key = if is_atom(k), do: Atom.to_string(k), else: k
      value = if is_map(v), do: stringify_keys(v), else: v
      {str_key, value}
    end)
  end
end
```
