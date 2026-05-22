# Code Smell: Compile-time Global Configuration

## Metadata

- **Smell name:** Compile-time global configuration
- **Expected smell location:** Module body, lines where `@from_address`, `@rate_limit_per_minute`, and `@smtp_pool_size` are defined
- **Affected function(s):** `send_email/1`, `send_bulk/2`, `build_message/1`
- **Short explanation:** `Application.fetch_env!/2` is called in the module body, binding three module attributes at compile time. Because the application environment is unavailable during compilation, this pattern can raise an `ArgumentError` or produce a compiler warning. The correct approach is to read these values at runtime inside the functions that consume them.

---

```elixir
defmodule Notifications.EmailSender do
  @moduledoc """
  Responsible for delivering transactional and bulk emails
  on behalf of platform services.

  Supports single sends and rate-limited bulk delivery with
  configurable sender address, SMTP pool size, and per-minute
  rate capping drawn from the application environment.
  """

  require Logger

  # VALIDATION: SMELL START - Compile-time global configuration
  # VALIDATION: This is a smell because Application.fetch_env!/2 is used in the
  # VALIDATION: module body to assign module attributes at compile time. The
  # VALIDATION: application environment is not available during compilation,
  # VALIDATION: which can raise ArgumentError or trigger a compiler warning.
  # VALIDATION: These values should be read at runtime within each function.
  @from_address        Application.fetch_env!(:notifications, :email_from_address)
  @rate_limit_per_min  Application.fetch_env!(:notifications, :email_rate_limit_per_minute)
  @smtp_pool_size      Application.fetch_env!(:notifications, :smtp_pool_size)
  # VALIDATION: SMELL END

  @max_bulk_recipients 500
  @retry_delay_ms      1_500

  @type email :: %{
    to:      String.t(),
    subject: String.t(),
    body:    String.t(),
    html?:   boolean()
  }

  @spec send_email(email()) :: :ok | {:error, String.t()}
  def send_email(%{to: to, subject: subject} = email) do
    Logger.debug("Preparing email", to: to, subject: subject, from: @from_address)

    with {:ok, message} <- build_message(email),
         :ok            <- dispatch(message) do
      Logger.info("Email delivered", to: to, subject: subject)
      :ok
    else
      {:error, reason} ->
        Logger.error("Email delivery failed", to: to, reason: reason)
        {:error, reason}
    end
  end

  @spec send_bulk([email()], keyword()) :: %{sent: integer(), failed: integer()}
  def send_bulk(emails, opts \\ []) when is_list(emails) do
    count = length(emails)

    if count > @max_bulk_recipients do
      raise ArgumentError,
            "Bulk send limit is #{@max_bulk_recipients}, got #{count}"
    end

    batch_size = Keyword.get(opts, :batch_size, @smtp_pool_size)
    interval   = round(60_000 / @rate_limit_per_min)

    Logger.info("Starting bulk send",
      total:      count,
      batch_size: batch_size,
      interval_ms: interval
    )

    emails
    |> Enum.chunk_every(batch_size)
    |> Enum.reduce(%{sent: 0, failed: 0}, fn batch, acc ->
      results = Enum.map(batch, &send_with_retry(&1, 3))

      sent   = Enum.count(results, &(&1 == :ok))
      failed = length(results) - sent

      Process.sleep(interval)

      %{sent: acc.sent + sent, failed: acc.failed + failed}
    end)
  end

  defp send_with_retry(email, attempts_left) do
    case send_email(email) do
      :ok ->
        :ok

      {:error, _reason} when attempts_left > 1 ->
        Process.sleep(@retry_delay_ms)
        send_with_retry(email, attempts_left - 1)

      {:error, reason} ->
        Logger.warn("Giving up on email after retries",
          to: email.to,
          reason: reason
        )
        {:error, reason}
    end
  end

  defp build_message(%{to: to, subject: subject, body: body, html?: true}) do
    {:ok, %{
      from:         @from_address,
      to:           to,
      subject:      subject,
      html_body:    body,
      text_body:    html_to_text(body),
      headers:      default_headers()
    }}
  end

  defp build_message(%{to: to, subject: subject, body: body}) do
    {:ok, %{
      from:      @from_address,
      to:        to,
      subject:   subject,
      text_body: body,
      headers:   default_headers()
    }}
  end

  defp dispatch(message) do
    Notifications.SMTPAdapter.deliver(message)
  rescue
    e ->
      {:error, Exception.message(e)}
  end

  defp default_headers do
    [
      {"X-Mailer", "Platform-Notifications/2.0"},
      {"X-From-Service", "notifications"}
    ]
  end

  defp html_to_text(html) do
    html
    |> String.replace(~r/<[^>]+>/, "")
    |> String.trim()
  end
end
```
