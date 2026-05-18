```elixir
defmodule Notifications.PreferenceLoader do
  @moduledoc """
  Loads and normalizes user notification preferences from the profile service.
  Preferences control which channels (email, SMS, push, etc.) receive alerts.
  """

  require Logger

  alias Notifications.{ProfileClient, PreferenceCache, ChannelRouter}

  @default_preferences %{
    channels: [:email],
    frequency: :immediate,
    quiet_hours_start: nil,
    quiet_hours_end: nil
  }

  @spec load(String.t()) :: {:ok, map()} | {:error, term()}
  def load(user_id) when is_binary(user_id) do
    case PreferenceCache.get(user_id) do
      {:hit, cached} ->
        {:ok, cached}

      :miss ->
        fetch_and_cache(user_id)
    end
  end

  defp fetch_and_cache(user_id) do
    case ProfileClient.get_preferences(user_id) do
      {:ok, raw_prefs} ->
        with {:ok, normalized} <- normalize(raw_prefs) do
          PreferenceCache.put(user_id, normalized)
          {:ok, normalized}
        end

      {:error, :not_found} ->
        Logger.info("No preferences found, using defaults", user_id: user_id)
        {:ok, @default_preferences}

      {:error, reason} ->
        Logger.error("Failed to fetch preferences",
          user_id: user_id,
          reason: inspect(reason)
        )
        {:error, reason}
    end
  end

  defp normalize(raw) when is_map(raw) do
    with {:ok, channels} <- parse_channels(raw["channels"]),
         {:ok, frequency} <- parse_frequency(raw["frequency"]) do
      prefs = %{
        channels: channels,
        frequency: frequency,
        quiet_hours_start: parse_time(raw["quiet_hours_start"]),
        quiet_hours_end: parse_time(raw["quiet_hours_end"]),
        topics: parse_topics(raw["topics"])
      }

      {:ok, prefs}
    end
  end

  defp normalize(_), do: {:error, :invalid_preference_format}

  defp parse_channels(nil), do: {:ok, [:email]}

  defp parse_channels(channels) when is_list(channels) do
    parsed =
      channels
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&parse_channel/1)
      |> Enum.reject(&is_nil/1)

    if parsed == [], do: {:error, :no_valid_channels}, else: {:ok, parsed}
  end

  defp parse_channels(_), do: {:error, :invalid_channels_format}

  defp parse_channel(channel) when is_binary(channel) do
    channel
    |> String.trim()
    |> String.downcase()
    |> String.to_atom()
  end

  defp parse_channel(_), do: nil

  defp parse_frequency(nil), do: {:ok, :immediate}
  defp parse_frequency("immediate"), do: {:ok, :immediate}
  defp parse_frequency("digest_daily"), do: {:ok, :digest_daily}
  defp parse_frequency("digest_weekly"), do: {:ok, :digest_weekly}
  defp parse_frequency(other) do
    Logger.warning("Unknown frequency value, defaulting to immediate", value: other)
    {:ok, :immediate}
  end

  defp parse_time(nil), do: nil
  defp parse_time(str) when is_binary(str) do
    case Time.from_iso8601(str) do
      {:ok, t} -> t
      _ -> nil
    end
  end

  defp parse_topics(nil), do: []
  defp parse_topics(topics) when is_list(topics) do
    Enum.filter(topics, &is_binary/1)
  end
  defp parse_topics(_), do: []
end
```
