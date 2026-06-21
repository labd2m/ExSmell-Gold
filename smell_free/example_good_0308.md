```elixir
defmodule Notifications.PreferenceStore do
  @moduledoc """
  Persists and evaluates per-user notification preferences. Users may
  opt out of specific event types, entire channels, or set quiet hours.
  The `deliverable?/3` predicate encapsulates all preference logic so
  delivery modules remain simple.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias Notifications.Preference

  @type user_id :: String.t()
  @type channel :: :email | :sms | :push
  @type event_type :: atom()

  @doc """
  Returns the preferences for `user_id`, or default permissive preferences
  when no record exists.
  """
  @spec fetch(user_id()) :: Preference.t()
  def fetch(user_id) when is_binary(user_id) do
    case Repo.get_by(Preference, user_id: user_id) do
      nil -> default_preference(user_id)
      pref -> pref
    end
  end

  @doc "Updates preferences for `user_id` with `attrs`."
  @spec upsert(user_id(), map()) :: {:ok, Preference.t()} | {:error, Ecto.Changeset.t()}
  def upsert(user_id, attrs) when is_binary(user_id) and is_map(attrs) do
    existing = Repo.get_by(Preference, user_id: user_id) || %Preference{user_id: user_id}

    existing
    |> Preference.changeset(attrs)
    |> Repo.insert_or_update()
  end

  @doc """
  Returns `true` when the notification for `event_type` on `channel`
  should be delivered to `user_id` right now. Checks channel opt-out,
  event-type opt-out, and quiet hours.
  """
  @spec deliverable?(user_id(), event_type(), channel()) :: boolean()
  def deliverable?(user_id, event_type, channel)
      when is_binary(user_id) and is_atom(event_type) and is_atom(channel) do
    pref = fetch(user_id)

    not channel_disabled?(pref, channel) and
      not event_type_muted?(pref, event_type) and
      not in_quiet_hours?(pref)
  end

  defp channel_disabled?(%Preference{disabled_channels: channels}, channel) do
    channel in (channels || [])
  end

  defp event_type_muted?(%Preference{muted_event_types: types}, event_type) do
    Atom.to_string(event_type) in (types || [])
  end

  defp in_quiet_hours?(%Preference{quiet_hours_start: nil}), do: false

  defp in_quiet_hours?(%Preference{quiet_hours_start: start_h, quiet_hours_end: end_h, timezone: tz}) do
    now = DateTime.utc_now()
    local_hour =
      case DateTime.shift_zone(now, tz || "Etc/UTC") do
        {:ok, local_dt} -> local_dt.hour
        _ -> now.hour
      end

    if start_h <= end_h do
      local_hour >= start_h and local_hour < end_h
    else
      local_hour >= start_h or local_hour < end_h
    end
  end

  defp default_preference(user_id) do
    %Preference{
      user_id: user_id,
      disabled_channels: [],
      muted_event_types: [],
      quiet_hours_start: nil,
      quiet_hours_end: nil,
      timezone: "Etc/UTC"
    }
  end
end
```
