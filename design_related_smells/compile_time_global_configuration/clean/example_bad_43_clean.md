```elixir
defmodule Mailer.SmtpRelay do
  @moduledoc """
  Low-level SMTP relay used by the application mailer.
  Responsible for opening connections to the mail server,
  authenticating, and submitting RFC-5321 messages.
  Supports STARTTLS and plain AUTH LOGIN.
  """

  require Logger

  @smtp_host Application.fetch_env!(:mailer, :smtp_host)

  @smtp_port 587
  @connect_timeout_ms 10_000
  @send_timeout_ms 30_000
  @max_recipients_per_message 50

  @type message :: %{
          from: String.t(),
          to: [String.t()],
          cc: [String.t()],
          subject: String.t(),
          text_body: String.t(),
          html_body: String.t() | nil,
          headers: [{String.t(), String.t()}]
        }

  @type deliver_result :: :ok | {:error, :connection_failed | :auth_failed | :send_failed | :too_many_recipients}

  @spec deliver(message()) :: deliver_result()
  def deliver(%{to: to} = message) when length(to) > @max_recipients_per_message do
    Logger.warning("Too many recipients", count: length(to), limit: @max_recipients_per_message)
    {:error, :too_many_recipients}
  end

  def deliver(message) do
    with {:ok, conn} <- open_connection(),
         :ok <- authenticate(conn),
         :ok <- submit_message(conn, message),
         :ok <- close_connection(conn) do
      Logger.info("Email delivered",
        from: message.from,
        to: message.to,
        subject: message.subject
      )

      :ok
    else
      {:error, :connection_failed} = err ->
        Logger.error("SMTP connection failed", host: @smtp_host, port: smtp_port())
        err

      {:error, :auth_failed} = err ->
        Logger.error("SMTP authentication failed", host: @smtp_host)
        err

      {:error, reason} ->
        Logger.error("SMTP delivery failed", reason: inspect(reason))
        {:error, :send_failed}
    end
  end

  @spec test_connection() :: :ok | {:error, atom()}
  def test_connection do
    case open_connection() do
      {:ok, conn} ->
        close_connection(conn)
        Logger.info("SMTP connection test passed", host: @smtp_host)
        :ok

      {:error, reason} ->
        Logger.error("SMTP connection test failed", host: @smtp_host, reason: inspect(reason))
        {:error, :connection_failed}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp open_connection do
    opts = [
      relay: @smtp_host,
      port: smtp_port(),
      ssl: use_ssl?(),
      tls: :if_available,
      auth: :always,
      hostname: :inet.gethostname() |> elem(1) |> to_string(),
      timeout: @connect_timeout_ms
    ]

    case :gen_smtp_client.open(opts) do
      {:ok, socket} -> {:ok, socket}
      {:error, _} -> {:error, :connection_failed}
    end
  rescue
    _ -> {:error, :connection_failed}
  end

  defp authenticate(conn) do
    username = Application.get_env(:mailer, :smtp_username, "")
    password = Application.get_env(:mailer, :smtp_password, "")

    case :gen_smtp_client.auth(conn, username, password) do
      :ok -> :ok
      _ -> {:error, :auth_failed}
    end
  rescue
    _ -> {:error, :auth_failed}
  end

  defp submit_message(conn, message) do
    mime = build_mime(message)

    case :gen_smtp_client.send_blocking({message.from, message.to, mime}, conn: conn,
           timeout: @send_timeout_ms) do
      {:ok, _} -> :ok
      _ -> {:error, :send_failed}
    end
  rescue
    _ -> {:error, :send_failed}
  end

  defp close_connection(conn) do
    :gen_smtp_client.close(conn)
    :ok
  rescue
    _ -> :ok
  end

  defp build_mime(%{from: from, to: to, subject: subject, text_body: text, html_body: html, headers: extra_headers}) do
    date = Calendar.strftime(DateTime.utc_now(), "%a, %d %b %Y %H:%M:%S +0000")

    base_headers = [
      {"From", from},
      {"To", Enum.join(to, ", ")},
      {"Subject", subject},
      {"Date", date},
      {"MIME-Version", "1.0"}
    ]

    all_headers = base_headers ++ extra_headers

    if html do
      boundary = "----=_Part_#{:rand.uniform(999_999)}"
      content_type = "multipart/alternative; boundary=\"#{boundary}\""
      body = "--#{boundary}\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n#{text}\r\n--#{boundary}\r\nContent-Type: text/html; charset=utf-8\r\n\r\n#{html}\r\n--#{boundary}--"
      :mimemail.encode({content_type, all_headers, body})
    else
      :mimemail.encode({"text/plain; charset=utf-8", all_headers, text})
    end
  end

  defp smtp_port, do: Application.get_env(:mailer, :smtp_port, @smtp_port)
  defp use_ssl?, do: Application.get_env(:mailer, :smtp_ssl, false)
end
```
