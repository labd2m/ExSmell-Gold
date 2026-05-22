```elixir
defmodule Notifications.EmailDispatcher do
  @moduledoc """
  Sends transactional emails (welcome, password reset, invoice) via the
  configured SMTP adapter. The default sender address is read from the
  application environment and used as the `From` header on every outgoing
  message.
  """

  require Logger

  @default_sender Application.fetch_env!(:notifications, :default_sender_email)

  @max_subject_length 78
  @text_plain "text/plain"
  @text_html "text/html"

  @type recipient :: %{name: String.t(), email: String.t()}
  @type send_result :: :ok | {:error, :invalid_recipient | :smtp_error | :rate_limited}

  @spec deliver_welcome(recipient()) :: send_result()
  def deliver_welcome(%{name: name, email: email} = recipient) do
    with :ok <- validate_recipient(recipient) do
      subject = "Welcome to the platform, #{name}!"
      text_body = welcome_text(name)
      html_body = welcome_html(name)

      send_email(
        from: @default_sender,
        to: email,
        subject: truncate_subject(subject),
        text: text_body,
        html: html_body
      )
    end
  end

  @spec deliver_password_reset(recipient(), String.t()) :: send_result()
  def deliver_password_reset(%{email: email} = recipient, reset_url)
      when is_binary(reset_url) do
    with :ok <- validate_recipient(recipient) do
      subject = "Reset your password"

      send_email(
        from: @default_sender,
        to: email,
        subject: subject,
        text: "Visit #{reset_url} to reset your password. Link expires in 30 minutes.",
        html: reset_html(reset_url)
      )
    end
  end

  @spec deliver_invoice(recipient(), String.t(), integer()) :: send_result()
  def deliver_invoice(%{name: name, email: email} = recipient, invoice_number, amount_cents)
      when is_binary(invoice_number) and is_integer(amount_cents) do
    with :ok <- validate_recipient(recipient) do
      formatted_amount = format_currency(amount_cents)
      subject = "Invoice #{invoice_number} — #{formatted_amount}"

      send_email(
        from: @default_sender,
        to: email,
        subject: subject,
        text: invoice_text(name, invoice_number, formatted_amount),
        html: invoice_html(name, invoice_number, formatted_amount)
      )
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp validate_recipient(%{email: email}) when is_binary(email) do
    if String.match?(email, ~r/\A[^@\s]+@[^@\s]+\z/), do: :ok, else: {:error, :invalid_recipient}
  end

  defp validate_recipient(_), do: {:error, :invalid_recipient}

  defp send_email(opts) do
    Logger.debug("Dispatching email", to: opts[:to], subject: opts[:subject])

    case smtp_adapter().send(opts) do
      :ok ->
        Logger.info("Email delivered", to: opts[:to])
        :ok

      {:error, :rate_limited} ->
        Logger.warning("SMTP rate limit hit", to: opts[:to])
        {:error, :rate_limited}

      {:error, reason} ->
        Logger.error("SMTP delivery failed", to: opts[:to], reason: inspect(reason))
        {:error, :smtp_error}
    end
  end

  defp smtp_adapter, do: Application.get_env(:notifications, :smtp_adapter, Notifications.SmtpAdapter)

  defp truncate_subject(subject) when byte_size(subject) > @max_subject_length do
    String.slice(subject, 0, @max_subject_length - 3) <> "..."
  end

  defp truncate_subject(subject), do: subject

  defp format_currency(cents) do
    dollars = cents / 100
    :io_lib.format("$~.2f", [dollars]) |> IO.iodata_to_binary()
  end

  defp welcome_text(name), do: "Hi #{name},\n\nWelcome! We are glad you joined.\n"
  defp welcome_html(name), do: "<p>Hi #{name},</p><p>Welcome! We are glad you joined.</p>"

  defp reset_html(url),
    do: ~s(<p>Click <a href="#{url}">here</a> to reset your password. Expires in 30 min.</p>)

  defp invoice_text(name, number, amount),
    do: "Hi #{name},\n\nYour invoice #{number} for #{amount} is ready.\n"

  defp invoice_html(name, number, amount),
    do: "<p>Hi #{name},</p><p>Invoice <strong>#{number}</strong> — #{amount}</p>"
end
```
