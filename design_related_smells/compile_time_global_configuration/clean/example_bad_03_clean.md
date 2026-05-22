```elixir
defmodule Notifications.Mailer do
  @moduledoc """
  Composes and dispatches transactional emails such as welcome messages,
  password resets, and invoice deliveries. Uses the configured SMTP adapter
  under the hood.
  """

  require Logger

  @sender_email Application.fetch_env!(:notifications, :sender_email)

  @sender_name "Acme Platform"
  @support_url "https://support.acme.io"
  @max_subject_length 78

  @type recipient :: %{email: String.t(), name: String.t()}
  @type mail_result :: :ok | {:error, term()}

  @doc """
  Sends a welcome email to a newly registered user.

  ## Parameters
    - `recipient` - A map with `:email` and `:name` keys.
  """
  @spec send_welcome(recipient()) :: mail_result()
  def send_welcome(%{email: email, name: name} = _recipient) do
    subject = "Welcome to #{@sender_name}, #{name}!"
    body = welcome_body(name)

    Logger.info("Sending welcome email to=#{email}")
    dispatch(email, subject, body)
  end

  @doc """
  Sends a password-reset link to the user.

  ## Parameters
    - `recipient` - A map with `:email` and `:name` keys.
    - `reset_token` - A short-lived token to include in the reset URL.
  """
  @spec send_password_reset(recipient(), String.t()) :: mail_result()
  def send_password_reset(%{email: email, name: name}, reset_token)
      when is_binary(reset_token) do
    reset_url = "#{@support_url}/password-reset?token=#{reset_token}"
    subject = "Reset your #{@sender_name} password"
    body = password_reset_body(name, reset_url)

    Logger.info("Sending password-reset email to=#{email}")
    dispatch(email, subject, body)
  end

  @doc """
  Sends an invoice email containing the billing details for a completed order.

  ## Parameters
    - `recipient` - A map with `:email` and `:name` keys.
    - `invoice` - A map with `:id`, `:amount_cents`, `:currency`, and `:line_items`.
  """
  @spec send_invoice(recipient(), map()) :: mail_result()
  def send_invoice(%{email: email, name: name}, invoice) do
    subject = truncate_subject("Your invoice ##{invoice.id} from #{@sender_name}")
    body = invoice_body(name, invoice)

    Logger.info("Sending invoice email to=#{email} invoice_id=#{invoice.id}")
    dispatch(email, subject, body)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp dispatch(to_email, subject, body) do
    message = %{
      from: {@sender_name, @sender_email},
      to: [to_email],
      subject: subject,
      html_body: body
    }

    case Notifications.SMTPAdapter.deliver(message) do
      :ok ->
        Logger.debug("Email delivered to=#{to_email} subject=#{inspect(subject)}")
        :ok

      {:error, reason} ->
        Logger.error("Email delivery failed to=#{to_email} reason=#{inspect(reason)}")
        {:error, reason}
    end
  end

  defp welcome_body(name) do
    """
    <h1>Hi #{name},</h1>
    <p>Welcome aboard! We're glad to have you.</p>
    <p>If you have any questions, visit our <a href="#{@support_url}">support centre</a>.</p>
    """
  end

  defp password_reset_body(name, reset_url) do
    """
    <p>Hi #{name},</p>
    <p>We received a request to reset your password. Click the link below:</p>
    <p><a href="#{reset_url}">Reset password</a></p>
    <p>This link expires in 30 minutes. If you did not request this, ignore this email.</p>
    """
  end

  defp invoice_body(name, invoice) do
    line_items_html =
      Enum.map_join(invoice.line_items, "\n", fn item ->
        "<tr><td>#{item.description}</td><td>#{item.amount_cents}</td></tr>"
      end)

    total = invoice.amount_cents / 100

    """
    <p>Hi #{name},</p>
    <p>Here is your invoice ##{invoice.id}.</p>
    <table>
      <thead><tr><th>Item</th><th>Amount</th></tr></thead>
      <tbody>#{line_items_html}</tbody>
      <tfoot><tr><td><strong>Total</strong></td><td>#{total} #{invoice.currency}</td></tr></tfoot>
    </table>
    """
  end

  defp truncate_subject(subject) when byte_size(subject) > @max_subject_length do
    String.slice(subject, 0, @max_subject_length - 3) <> "..."
  end

  defp truncate_subject(subject), do: subject
end
```
