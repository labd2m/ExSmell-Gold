# Annotated Example — Speculative Assumptions

## Metadata

- **Smell name:** Speculative Assumptions
- **Expected smell location:** `Notifications.ConfigReader.load_channel/1`, around the map key access
- **Affected function(s):** `load_channel/1`
- **Short explanation:** The function uses `Map.get/3` with default fallback values to read all notification channel configuration fields. If the configuration map is missing a critical key (e.g., `"endpoint"` or `"api_key"`), `Map.get/3` silently returns the default instead of crashing. This means the system proceeds to send notifications using a wrong or empty endpoint/key, producing incorrect behavior that looks like success from the outside.

---

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

  # VALIDATION: SMELL START - Speculative Assumptions
  # VALIDATION: This is a smell because the function uses Map.get/3 with default values
  # VALIDATION: for every field, including critical ones like "endpoint", "api_key",
  # VALIDATION: and "sender". If the configuration is incomplete or mistyped (e.g.,
  # VALIDATION: "api_key" is stored as "apikey"), Map.get/3 silently returns ""
  # VALIDATION: or a default value. The function always returns a seemingly complete
  # VALIDATION: channel struct even when vital fields are missing, and the caller
  # VALIDATION: has no way to distinguish a properly loaded channel from a broken one
  # VALIDATION: until an actual notification attempt fails — possibly silently.
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
  # VALIDATION: SMELL END

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
