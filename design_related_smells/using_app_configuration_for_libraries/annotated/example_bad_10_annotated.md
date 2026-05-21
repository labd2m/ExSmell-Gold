# Annotated Example 10

## Metadata

- **Smell name:** Using App Configuration for libraries
- **Expected smell location:** `EmailFormatter.format_recipients/1`
- **Affected function(s):** `format_recipients/1`
- **Short explanation:** The library reads `:max_recipients` from the application environment via `Application.fetch_env!/2` instead of accepting it as a parameter. This forces every caller across the entire application to share the same limit, preventing different parts of the system from formatting recipient lists with different constraints.

## Code

```elixir
defmodule EmailFormatter do
  @moduledoc """
  A library for formatting outgoing email payloads according to standard
  delivery conventions. Intended to be used across multiple applications
  that need consistent email structure before handing off to an SMTP adapter.
  """

  alias EmailFormatter.Address

  @default_display_name_max 64
  @header_safe_chars ~r/[^\x20-\x7E]/

  @doc """
  Formats a list of recipient structs into RFC 5321-compliant address strings
  and enforces a configurable upper bound on the number of recipients per message.

  The maximum recipient count is read from the application environment:

      config :email_formatter, max_recipients: 20

  Raises if the number of recipients exceeds the configured limit.
  """
  # VALIDATION: SMELL START - Using App Configuration for libraries
  # VALIDATION: This is a smell because max_recipients is fetched from the
  # Application Environment instead of being an optional parameter (e.g., opts keyword list).
  # This makes it impossible for callers to use different limits in different contexts
  # within the same application without changing the global config.
  def format_recipients(recipients) when is_list(recipients) do
    max = Application.fetch_env!(:email_formatter, :max_recipients)

    if length(recipients) > max do
      raise ArgumentError,
            "recipient count #{length(recipients)} exceeds configured max of #{max}"
    end
    # VALIDATION: SMELL END

    recipients
    |> Enum.map(&format_single/1)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Formats a plain-text subject line, stripping non-printable characters
  and trimming whitespace.
  """
  def format_subject(subject) when is_binary(subject) do
    subject
    |> String.replace(@header_safe_chars, "")
    |> String.trim()
    |> truncate(998)
  end

  @doc """
  Builds the final email map ready for hand-off to an SMTP adapter.
  """
  def build(attrs) when is_map(attrs) do
    %{
      from: format_single(Map.fetch!(attrs, :from)),
      to: format_recipients(Map.get(attrs, :to, [])),
      cc: format_recipients(Map.get(attrs, :cc, [])),
      bcc: format_recipients(Map.get(attrs, :bcc, [])),
      subject: format_subject(Map.get(attrs, :subject, "")),
      body: Map.get(attrs, :body, ""),
      headers: build_headers(attrs)
    }
  end

  @doc """
  Validates that an address struct has the required fields populated.
  """
  def valid_address?(%Address{email: email}) when is_binary(email) do
    String.match?(email, ~r/\A[^@\s]+@[^@\s]+\z/)
  end

  def valid_address?(_), do: false

  ## Private helpers

  defp format_single(%Address{email: email, name: nil}) do
    if valid_email?(email), do: email, else: nil
  end

  defp format_single(%Address{email: email, name: name}) do
    display = name |> sanitize_display() |> truncate(@default_display_name_max)

    if valid_email?(email) do
      ~s("#{display}" <#{email}>)
    else
      nil
    end
  end

  defp format_single(email) when is_binary(email) do
    if valid_email?(email), do: email, else: nil
  end

  defp format_single(_), do: nil

  defp valid_email?(email) when is_binary(email) do
    String.match?(email, ~r/\A[^@\s]+@[^@\s]+\z/)
  end

  defp sanitize_display(name) when is_binary(name) do
    name
    |> String.replace(~r/[\"\\]/, "")
    |> String.replace(@header_safe_chars, "")
    |> String.trim()
  end

  defp build_headers(attrs) do
    base = %{"MIME-Version" => "1.0", "Content-Type" => "text/plain; charset=UTF-8"}

    attrs
    |> Map.get(:extra_headers, %{})
    |> Enum.reduce(base, fn {k, v}, acc ->
      Map.put(acc, sanitize_display(to_string(k)), sanitize_display(to_string(v)))
    end)
  end

  defp truncate(str, max) when byte_size(str) <= max, do: str
  defp truncate(str, max), do: binary_part(str, 0, max)
end
```
