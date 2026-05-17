```elixir
defmodule Notifications.ConfigReader do
  @moduledoc """
  Reads and validates notification channel configuration from the application
  environment. Supports email, SMS, push, and webhook channels.

  Configuration is stored as a map under :notifications, :channels in the
  application config.
  """

  require Logger

  @supported_channels ~w(email sms push webhook)a

  def load_all_channels do
    :notifications
    |> Application.get_env(:channels, [])
    |> Enum.map(fn {name, config} -> {name, load_channel(config)} end)
    |> Map.new()
  end

  def load_channel(config) when is_map(config) do
    %{
      type:          Map.get(config, "type", "email"),
      endpoint:      Map.get(config, "endpoint", ""),
      api_key:       Map.get(config, "api_key", ""),
      sender:        Map.get(config, "sender", "no-reply@example.com"),
      timeout_ms:    Map.get(config, "timeout_ms", 5000),
      retry_count:   Map.get(config, "retry_count", 3),
      enabled:       Map.get(config, "enabled", true),
      rate_limit:    Map.get(config, "rate_limit", 100),
      template_path: Map.get(config, "template_path", "priv/templates")
    }
  end

  def load_channel(_), do: {:error, :invalid_config}

  def validate_channel(%{type: type, endpoint: ep, api_key: key} = channel) do
    cond do
      type not in Enum.map(@supported_channels, &Atom.to_string/1) ->
        {:error, {:unsupported_type, type}}

      ep == "" ->
        {:error, :missing_endpoint}

      key == "" and type in ["sms", "push", "webhook"] ->
        {:error, :missing_api_key}

      not channel.enabled ->
        {:error, :channel_disabled}

      true ->
        {:ok, channel}
    end
  end

  def get_active_channels(channels_map) do
    channels_map
    |> Enum.filter(fn {_name, ch} -> is_map(ch) and ch.enabled end)
    |> Map.new()
  end

  def channel_for_type(channels_map, type) do
    channels_map
    |> Enum.find(fn {_name, ch} -> is_map(ch) and ch.type == to_string(type) end)
    |> case do
      {name, ch} -> {:ok, name, ch}
      nil        -> {:error, :no_channel_for_type}
    end
  end

  def describe_channel(%{type: type, endpoint: ep, enabled: enabled, rate_limit: rl}) do
    status = if enabled, do: "active", else: "disabled"
    "#{type} channel — #{ep} [#{status}, rate_limit=#{rl}/min]"
  end

  def reload! do
    Logger.info("Reloading notification channel configuration")
    load_all_channels()
  end

  def export_summary(channels_map) do
    channels_map
    |> Enum.map(fn {name, ch} ->
      %{
        name:    name,
        type:    Map.get(ch, :type, "unknown"),
        enabled: Map.get(ch, :enabled, false)
      }
    end)
  end
end
```
