```elixir
defmodule Notifications.PushTargetParser do
  @moduledoc """
  Decodes push notification target descriptor strings used by the mobile notification service.

  The notification service stores push targets as a compact descriptor that bundles
  the delivery platform, the device-specific registration token, and the deployment
  environment in a single pipe-delimited string:

    "<PLATFORM>|<DEVICE_TOKEN>|<ENVIRONMENT>"

  Platforms:
    fcm   — Firebase Cloud Messaging (Android + Web Push)
    apns  — Apple Push Notification Service (iOS + macOS)
    wns   — Windows Notification Service (Windows / UWP)
    huawei — Huawei Push Kit

  Environments:
    production  — Live user devices
    sandbox     — Development / TestFlight / debug devices

  Examples:
    "fcm|dGhpcyBpcyBhIHRva2Vu|production"
    "apns|AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA|sandbox"
    "wns|ms-app://s-1-15-2-1234567890-|production"
  """

  require Logger

  @known_platforms    ~w(fcm apns wns huawei)
  @known_environments ~w(production sandbox)

  defstruct [:platform, :device_token, :environment, :raw]

  @doc """
  Decodes a push target descriptor string into a `%PushTargetParser{}` struct.

  Returns `{:ok, struct}` when the platform and environment are recognised.
  Returns `{:error, reason}` when either validation fails.
  """

  def decode(descriptor) when is_binary(descriptor) do
    parts        = String.split(descriptor, "|")
    platform     = Enum.at(parts, 0)
    device_token = Enum.at(parts, 1)
    environment  = Enum.at(parts, 2)

    with :ok <- validate_platform(platform),
         :ok <- validate_environment(environment) do
      {:ok, %__MODULE__{
        platform:     platform,
        device_token: device_token,
        environment:  environment,
        raw:          descriptor
      }}
    end
  end

  @doc """
  Decodes a list of push target descriptor strings.
  """
  def decode_many(descriptors) when is_list(descriptors) do
    Enum.reduce(descriptors, %{ok: [], error: []}, fn desc, acc ->
      case decode(desc) do
        {:ok, target}    -> %{acc | ok:    [target | acc.ok]}
        {:error, reason} -> %{acc | error: [{desc, reason} | acc.error]}
      end
    end)
    |> then(&%{&1 | ok: Enum.reverse(&1.ok), error: Enum.reverse(&1.error)})
  end

  @doc """
  Encodes a `%PushTargetParser{}` struct back into its descriptor string.
  """
  def encode(%__MODULE__{platform: p, device_token: t, environment: e}) do
    "#{p}|#{t}|#{e}"
  end

  @doc """
  Returns true when the target is a production device (real user).
  """
  def production?(%__MODULE__{environment: "production"}), do: true
  def production?(_), do: false

  @doc """
  Returns true when the target uses Apple Push Notification Service.
  """
  def apns?(%__MODULE__{platform: "apns"}), do: true
  def apns?(_), do: false

  @doc """
  Returns a redacted representation safe for log output.
  """
  def redact(%__MODULE__{platform: p, device_token: t, environment: e}) do
    token_prefix = String.slice(t || "", 0, 6)
    "#{p}|#{token_prefix}...|#{e}"
  end

  @doc """
  Groups a list of decoded targets by platform.
  """
  def group_by_platform(targets) when is_list(targets) do
    Enum.group_by(targets, & &1.platform)
  end

  @doc """
  Returns all supported platform identifiers.
  """
  def known_platforms, do: @known_platforms

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp validate_platform(p) when is_binary(p) do
    if p in @known_platforms, do: :ok, else: {:error, {:unknown_platform, p}}
  end

  defp validate_platform(nil), do: {:error, :missing_platform}
  defp validate_platform(_),   do: {:error, :invalid_platform}

  defp validate_environment(e) when is_binary(e) do
    if e in @known_environments, do: :ok, else: {:error, {:unknown_environment, e}}
  end

  defp validate_environment(nil), do: {:error, :missing_environment}
  defp validate_environment(_),   do: {:error, :invalid_environment}
end
```
