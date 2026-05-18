```elixir
defmodule MyApp.Notifications.NotificationPreferences do
  @moduledoc """
  Manages per-user notification channel preferences.
  Preferences are stored as JSON in the database and decoded at read time.
  """

  require Logger

  alias MyApp.Repo
  alias MyApp.Accounts.User

  @valid_channels [:email, :sms, :push, :in_app, :slack, :webhook]
  @valid_frequencies [:immediate, :hourly, :daily, :weekly, :never]

  @default_preferences %{
    channels: [:email, :in_app],
    frequency: :immediate,
    quiet_hours_start: ~T[22:00:00],
    quiet_hours_end: ~T[07:00:00],
    categories: %{}
  }

  @doc """
  Returns the decoded preferences struct for a given user ID.
  Falls back to defaults if no preferences are stored.
  """
  @spec get(integer()) :: map()
  def get(user_id) when is_integer(user_id) do
    case Repo.get_preference_row(user_id) do
      nil ->
        @default_preferences

      %{"channels" => channels, "frequency" => frequency} = row ->
        %{
          channels: decode_channels(channels),
          frequency: decode_frequency(frequency),
          quiet_hours_start: decode_time(row["quiet_hours_start"], @default_preferences.quiet_hours_start),
          quiet_hours_end: decode_time(row["quiet_hours_end"], @default_preferences.quiet_hours_end),
          categories: decode_categories(row["categories"] || %{})
        }
    end
  end

  @doc """
  Persists updated preferences for a user.
  Validates channels and frequency before saving.
  """
  @spec update(integer(), map()) :: {:ok, map()} | {:error, term()}
  def update(user_id, params) when is_integer(user_id) and is_map(params) do
    with {:ok, channels} <- validate_channels(Map.get(params, "channels", [])),
         {:ok, frequency} <- validate_frequency(Map.get(params, "frequency", "immediate")) do
      payload = %{
        "channels" => Enum.map(channels, &Atom.to_string/1),
        "frequency" => Atom.to_string(frequency),
        "quiet_hours_start" => Map.get(params, "quiet_hours_start"),
        "quiet_hours_end" => Map.get(params, "quiet_hours_end"),
        "categories" => Map.get(params, "categories", %{})
      }

      case Repo.upsert_preference_row(user_id, payload) do
        {:ok, _} -> {:ok, get(user_id)}
        {:error, _} = err -> err
      end
    end
  end

  defp decode_channels(channels) when is_list(channels) do
    channels
    |> Enum.map(&String.to_atom/1)
    |> Enum.filter(&(&1 in @valid_channels))
  end

  defp decode_channels(_), do: @default_preferences.channels

  defp decode_frequency(freq) when is_binary(freq) do
    case Enum.find(@valid_frequencies, &(Atom.to_string(&1) == freq)) do
      nil -> @default_preferences.frequency
      atom -> atom
    end
  end

  defp decode_frequency(_), do: @default_preferences.frequency

  defp decode_time(nil, default), do: default

  defp decode_time(str, default) when is_binary(str) do
    case Time.from_iso8601(str) do
      {:ok, t} -> t
      _ -> default
    end
  end

  defp decode_categories(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      {k, decode_frequency(v)}
    end)
  end

  defp validate_channels(channels) when is_list(channels) do
    atoms =
      channels
      |> Enum.flat_map(fn ch ->
        case Enum.find(@valid_channels, &(Atom.to_string(&1) == ch)) do
          nil -> []
          atom -> [atom]
        end
      end)

    {:ok, atoms}
  end

  defp validate_channels(_), do: {:error, :invalid_channels}

  defp validate_frequency(freq) when is_binary(freq) do
    case Enum.find(@valid_frequencies, &(Atom.to_string(&1) == freq)) do
      nil -> {:error, :invalid_frequency}
      atom -> {:ok, atom}
    end
  end
end
```
