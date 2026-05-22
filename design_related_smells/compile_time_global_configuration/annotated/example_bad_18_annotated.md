# Annotated Bad Example 18

## Metadata

- **Smell name:** Compile-time global configuration
- **Expected smell location:** Module attribute `@smtp_host` defined at the top of `Mailer.SMTPAdapter`
- **Affected function(s):** `deliver/1`, `deliver_many/1`
- **Short explanation:** `Application.fetch_env!/2` is used in the module body to read the SMTP host into a module attribute. Module attributes are evaluated during compilation, but the `:mailer` application configuration is only available at runtime, so this pattern can trigger a warning or `ArgumentError` at compile-time.

---

```elixir
defmodule Mailer.SMTPAdapter do
  @moduledoc """
  Low-level SMTP delivery adapter used by higher-level mailer modules.
  Wraps gen_smtp to open authenticated SMTP connections and deliver
  RFC-2822 formatted messages. Supports both single and batched delivery.
  """

  require Logger

  @smtp_port 587
  @smtp_tls :always
  @smtp_retries 2

  # VALIDATION: SMELL START - Compile-time global configuration
  # VALIDATION: This is a smell because Application.fetch_env!/2 is called in the
  # VALIDATION: module body to populate a module attribute with the SMTP hostname.
  # VALIDATION: Module attributes are frozen at compile-time; at that stage the
  # VALIDATION: :mailer OTP application configuration may not be loaded yet, causing
  # VALIDATION: Elixir to raise a warning or ArgumentError during compilation.
  @smtp_host Application.fetch_env!(:mailer, :smtp_host)
  # VALIDATION: SMELL END

  @type email_message :: %{
          from: {String.t(), String.t()},
          to: [String.t()],
          subject: String.t(),
          html_body: String.t(),
          text_body: String.t() | nil,
          reply_to: String.t() | nil
        }

  @doc """
  Delivers a single email via SMTP.

  ## Parameters
    - `message` - An email message map with `:from`, `:to`, `:subject`, and
      `:html_body` keys. `:text_body` and `:reply_to` are optional.

  ## Returns
    - `:ok` on success.
    - `{:error, reason}` on failure.
  """
  @spec deliver(email_message()) :: :ok | {:error, term()}
  def deliver(message) when is_map(message) do
    Logger.info("Delivering email to=#{inspect(message.to)} subject=#{inspect(message.subject)}")

    with {:ok, conn} <- open_connection(),
         {:ok, _receipt} <- send_message(conn, message) do
      :gen_smtp_client.stop(conn)
      Logger.info("Email delivered to=#{inspect(message.to)}")
      :ok
    else
      {:error, reason} = err ->
        Logger.error("SMTP delivery failed reason=#{inspect(reason)}")
        err
    end
  end

  @doc """
  Delivers multiple emails, reusing a single SMTP connection for efficiency.
  Returns a list of per-message results in the same order as `messages`.

  ## Parameters
    - `messages` - A list of email message maps.
  """
  @spec deliver_many([email_message()]) :: [{:ok, String.t()} | {:error, term()}]
  def deliver_many(messages) when is_list(messages) do
    Logger.info("Batch delivering #{length(messages)} emails")

    case open_connection() do
      {:ok, conn} ->
        results = Enum.map(messages, fn msg -> send_message(conn, msg) end)
        :gen_smtp_client.stop(conn)
        results

      {:error, reason} ->
        Logger.error("Could not open SMTP connection reason=#{inspect(reason)}")
        Enum.map(messages, fn _ -> {:error, :connection_failed} end)
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp open_connection do
    username = Application.get_env(:mailer, :smtp_username, "")
    password = Application.get_env(:mailer, :smtp_password, "")

    relay_opts = [
      relay: @smtp_host,
      port: @smtp_port,
      tls: @smtp_tls,
      username: username,
      password: password,
      retries: @smtp_retries,
      auth: :always
    ]

    case :gen_smtp_client.open(relay_opts) do
      {:ok, socket} -> {:ok, socket}
      {:error, reason} -> {:error, reason}
    end
  end

  defp send_message(conn, %{from: {_name, from_addr}, to: to_addrs} = message) do
    mime = build_mime(message)

    case :gen_smtp_client.send_blocking({from_addr, to_addrs, mime}, [{:relay, conn}]) do
      receipt when is_binary(receipt) -> {:ok, receipt}
      {:error, _, reason} -> {:error, reason}
    end
  end

  defp build_mime(%{from: {name, addr}, to: to_addrs, subject: subject} = msg) do
    text_part = msg[:text_body] || html_to_text(msg.html_body)

    :mimemail.encode({
      "multipart",
      "alternative",
      [
        {"From", "#{name} <#{addr}>"},
        {"To", Enum.join(to_addrs, ", ")},
        {"Subject", subject},
        {"MIME-Version", "1.0"}
      ],
      %{},
      [
        {"text", "plain", [], %{}, text_part},
        {"text", "html", [], %{}, msg.html_body}
      ]
    })
  end

  defp html_to_text(html) do
    html
    |> String.replace(~r/<[^>]+>/, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end
```
