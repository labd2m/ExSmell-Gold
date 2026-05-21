```elixir
defmodule EmailFormatter do
  @moduledoc """
  A library for formatting and validating email addresses used in outbound
  mailer pipelines. Provides utilities for building RFC-5321-compliant
  address strings, normalizing local parts, and constructing reply-to headers.

  Configuration (in config/config.exs of the host application):

      config :email_formatter,
        sender_name: "Acme Support",
        default_domain: "mail.acme.io"
  """

  @email_regex ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/


  @doc """
  Formats a raw email address into a display string using the globally
  configured sender name.

  ## Examples

      iex> EmailFormatter.format_address("support@acme.io")
      "Acme Support <support@acme.io>"
  """
  @spec format_address(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def format_address(address) when is_binary(address) do
    sender_name = Application.fetch_env!(:email_formatter, :sender_name)

    case validate_address(address) do
      :ok -> {:ok, "#{sender_name} <#{String.downcase(address)}>"}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Builds a reply-to header value, falling back to the configured default
  domain when no local part is supplied.
  """
  @spec build_reply_to(String.t() | nil) :: String.t()
  def build_reply_to(local_part) do
    default_domain = Application.fetch_env!(:email_formatter, :default_domain)

    normalized =
      case local_part do
        nil -> "noreply"
        "" -> "noreply"
        part -> normalize_local_part(part)
      end

    "#{normalized}@#{default_domain}"
  end


  @doc """
  Validates that the given string conforms to a basic email format.
  """
  @spec validate_address(String.t()) :: :ok | {:error, String.t()}
  def validate_address(address) when is_binary(address) do
    cond do
      String.length(address) > 254 ->
        {:error, "Address exceeds maximum length of 254 characters"}

      not Regex.match?(@email_regex, address) ->
        {:error, "Address does not match expected format"}

      String.contains?(address, "..") ->
        {:error, "Address contains consecutive dots"}

      true ->
        :ok
    end
  end

  @doc """
  Extracts the domain part from a valid email address.
  """
  @spec extract_domain(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def extract_domain(address) when is_binary(address) do
    case validate_address(address) do
      :ok ->
        domain =
          address
          |> String.split("@")
          |> List.last()
          |> String.downcase()

        {:ok, domain}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Normalizes an email address by lowercasing and trimming whitespace.
  """
  @spec normalize(String.t()) :: String.t()
  def normalize(address) when is_binary(address) do
    address
    |> String.trim()
    |> String.downcase()
  end

  @doc """
  Returns true if two email addresses refer to the same mailbox (case-insensitive).
  """
  @spec same_mailbox?(String.t(), String.t()) :: boolean()
  def same_mailbox?(address_a, address_b)
      when is_binary(address_a) and is_binary(address_b) do
    normalize(address_a) == normalize(address_b)
  end

  # --- Private helpers ---

  defp normalize_local_part(part) do
    part
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9.\-_+]/, "")
  end
end
```
