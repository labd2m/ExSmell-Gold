# Annotated Example 23

## Metadata

- **Smell name:** Using App Configuration for libraries
- **Expected smell location:** `SmsComposer.compose/2`
- **Affected function(s):** `compose/2`
- **Short explanation:** The library function `compose/2` fetches `:max_sms_length` and `:truncation_suffix` from the `Application` environment. This prevents dependent applications from composing SMS messages with different length constraints in different channels (e.g., standard 160-char SMS vs. a 300-char MMS gateway), because the limit is locked into shared global config rather than being a function parameter.

---

```elixir
defmodule SmsComposer do
  @moduledoc """
  Library for composing and validating outbound SMS messages.
  Used by notification services, alert dispatchers, and
  two-factor authentication flows.
  """

  @type message :: %{
          to: String.t(),
          body: String.t(),
          sender_id: String.t()
        }

  @type compose_error ::
          {:error, :invalid_recipient}
          | {:error, :empty_body}
          | {:error, :invalid_sender}

  @doc """
  Composes an SMS message map from a recipient, body template, and
  a keyword list of template bindings. The message body is truncated
  to the configured maximum length if necessary.
  """
  @spec compose(String.t(), String.t(), Keyword.t(), String.t()) ::
          {:ok, message()} | compose_error()
  def compose(recipient, template, bindings \\ [], sender_id) do
    with :ok <- validate_recipient(recipient),
         :ok <- validate_sender(sender_id),
         body <- render_template(template, bindings),
         :ok <- validate_body(body) do
      # VALIDATION: SMELL START - Using App Configuration for libraries
      # VALIDATION: This is a smell because compose/4 is a library function that
      # reads :max_sms_length and :truncation_suffix from the Application environment
      # instead of accepting them as parameters. This makes it impossible for a
      # dependent application to compose messages with different length limits
      # (e.g., 160 chars for a basic SMS gateway vs. 306 chars for a concatenated
      # message gateway) in different call sites without mutating global config.
      max_length = Application.fetch_env!(:sms_composer, :max_sms_length)
      suffix = Application.get_env(:sms_composer, :truncation_suffix, "…")
      # VALIDATION: SMELL END

      trimmed_body = truncate(body, max_length, suffix)
      {:ok, %{to: recipient, body: trimmed_body, sender_id: sender_id}}
    end
  end

  @doc """
  Splits a long message body into multiple SMS-sized segments.
  Useful for sending multi-part messages via gateways that do not
  support automatic concatenation.
  """
  @spec split_segments(String.t(), pos_integer()) :: [String.t()]
  def split_segments(body, segment_size) when is_binary(body) and is_integer(segment_size) do
    body
    |> String.graphemes()
    |> Enum.chunk_every(segment_size)
    |> Enum.map(&Enum.join/1)
  end

  @doc "Returns the estimated segment count for a body string."
  @spec segment_count(String.t(), pos_integer()) :: non_neg_integer()
  def segment_count(body, segment_size) when is_binary(body) do
    ceil(String.length(body) / segment_size)
  end

  @doc "Returns true if the recipient phone number looks plausibly valid."
  @spec valid_recipient?(String.t()) :: boolean()
  def valid_recipient?(number) when is_binary(number) do
    Regex.match?(~r/^\+?[1-9]\d{6,14}$/, String.replace(number, ~r/[\s\-()]/, ""))
  end

  @doc "Renders a simple template by substituting {{key}} placeholders."
  @spec render_template(String.t(), Keyword.t()) :: String.t()
  def render_template(template, bindings) when is_binary(template) and is_list(bindings) do
    Enum.reduce(bindings, template, fn {key, value}, acc ->
      String.replace(acc, "{{#{key}}}", to_string(value))
    end)
  end

  @doc "Returns the character count of a composed message body."
  @spec char_count(message()) :: non_neg_integer()
  def char_count(%{body: body}), do: String.length(body)

  # --- Private helpers ---

  defp validate_recipient(number) do
    if valid_recipient?(number), do: :ok, else: {:error, :invalid_recipient}
  end

  defp validate_sender(sender) do
    cond do
      not is_binary(sender) -> {:error, :invalid_sender}
      String.length(sender) < 1 -> {:error, :invalid_sender}
      String.length(sender) > 11 -> {:error, :invalid_sender}
      true -> :ok
    end
  end

  defp validate_body(""), do: {:error, :empty_body}
  defp validate_body(body) when is_binary(body), do: :ok

  defp truncate(body, max_length, suffix) do
    if String.length(body) <= max_length do
      body
    else
      safe_len = max_length - String.length(suffix)
      String.slice(body, 0, safe_len) <> suffix
    end
  end
end
```
