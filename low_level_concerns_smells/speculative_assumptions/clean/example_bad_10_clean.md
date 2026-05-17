```elixir
defmodule Notifications.ChannelAddressParser do
  @moduledoc """
  Parses notification channel address descriptors used by the dispatch engine.

  The dispatcher accepts a unified address format that encodes the delivery
  channel and the destination address in a single string, allowing heterogeneous
  channel lists to be stored as plain text in the database.

  Supported channel formats:
    "email:<recipient@domain.com>"
    "sms:<E.164 phone number>"
    "slack:<#channel-name or @user-handle>"
    "webhook:<https://destination.example.com/hook>"
    "push:<device_registration_token>"

  Examples:
    "email:alice@acme.com"
    "sms:+61412345678"
    "slack:#ops-alerts"
    "webhook:https://hooks.example.com/notify"
    "push:dGhpcyBpcyBhIHRva2Vu"
  """

  require Logger

  @supported_channels ~w(email sms slack webhook push)

  @doc """
  Parses a raw channel address string into a structured map.

  Returns `{:ok, %{channel: channel, address: address}}` on success,
  or `{:error, reason}` if the channel is unsupported or the string is nil.
  """

  def parse(nil), do: {:error, :missing_address}

  def parse(raw) when is_binary(raw) do
    parts   = String.split(raw, ":")
    channel = Enum.at(parts, 0)
    address = Enum.at(parts, 1)

    if channel in @supported_channels do
      {:ok, %{channel: channel, address: address, raw: raw}}
    else
      {:error, {:unsupported_channel, channel}}
    end
  end

  @doc """
  Parses a list of raw channel address strings.

  Returns a map with `:ok` and `:error` keys containing the
  respective results.
  """
  def parse_many(raw_list) when is_list(raw_list) do
    results = Enum.map(raw_list, &parse/1)

    %{
      ok:    for({:ok, info}       <- results, do: info),
      error: for({:error, reason}  <- results, do: reason)
    }
  end

  @doc """
  Returns true if the parsed channel address passes basic structural validation.
  """
  def valid?({:ok, %{channel: channel, address: address}}) do
    valid_channel?(channel) and valid_address?(channel, address)
  end

  def valid?(_), do: false

  @doc """
  Returns a sanitised log-safe representation of a parsed address.
  Masks the address portion for privacy-sensitive channels.
  """
  def redact(%{channel: "email", address: address}) when is_binary(address) do
    [local | _] = String.split(address, "@")
    masked_local = String.slice(local, 0, 2) <> "***"
    "email:#{masked_local}@[REDACTED]"
  end

  def redact(%{channel: "sms", address: address}) when is_binary(address) do
    visible = String.slice(address, 0, 4)
    "sms:#{visible}***"
  end

  def redact(%{channel: channel, address: address}) do
    "#{channel}:#{String.slice(address || "", 0, 8)}***"
  end

  @doc """
  Groups a list of parsed channel address maps by their channel type.
  """
  def group_by_channel(parsed_list) when is_list(parsed_list) do
    Enum.group_by(parsed_list, & &1.channel)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp valid_channel?(channel), do: channel in @supported_channels

  defp valid_address?("email", address) when is_binary(address) do
    Regex.match?(~r/\A[^@\s]+@[^@\s]+\.[^@\s]+\z/, address)
  end

  defp valid_address?("sms", address) when is_binary(address) do
    Regex.match?(~r/\A\+[1-9]\d{6,14}\z/, address)
  end

  defp valid_address?("slack", address) when is_binary(address) do
    String.starts_with?(address, "#") or String.starts_with?(address, "@")
  end

  defp valid_address?("webhook", address) when is_binary(address) do
    String.starts_with?(address, "https://")
  end

  defp valid_address?("push", address) when is_binary(address) do
    byte_size(address) >= 16
  end

  defp valid_address?(_, _), do: false
end
```
