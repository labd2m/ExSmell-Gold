# Annotated Example 10

## Metadata

- **Smell name:** Speculative Assumptions
- **Expected smell location:** `Notifications.ChannelAddressParser.parse/1`
- **Affected function(s):** `parse/1`
- **Short explanation:** The function splits a channel address string on `":"` and extracts the
  channel type at index 0 and the address at index 1 using `Enum.at/2`. This silently breaks for
  `mailto:` URIs (`"email:user@company.com"` is fine, but real mailto URIs such as
  `"mailto:user@company.com"` split differently) and completely fails for addresses that
  legitimately contain colons — e.g. an IPv6 address in a webhook URL
  (`"webhook:https://2001:db8::1/notify"`). Instead of crashing, it returns a map with a
  truncated or wrong address, giving a false impression of correct parsing.

---

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

  # VALIDATION: SMELL START - Speculative Assumptions
  # VALIDATION: This is a smell because the function splits on ":" with no limit and
  # VALIDATION: uses `Enum.at(parts, 0)` and `Enum.at(parts, 1)` to retrieve the
  # VALIDATION: channel and address. For webhook addresses that contain HTTPS URLs
  # VALIDATION: ("webhook:https://hooks.example.com/notify"), the split on ":" produces
  # VALIDATION: ["webhook", "https", "//hooks.example.com/notify"]. `Enum.at(parts, 1)`
  # VALIDATION: silently returns "https" — not the intended URL — and the address field
  # VALIDATION: receives an obviously wrong value with no error raised. The caller sees
  # VALIDATION: {:ok, %{channel: "webhook", address: "https"}} and proceeds as if parsing
  # VALIDATION: succeeded.
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
  # VALIDATION: SMELL END

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
