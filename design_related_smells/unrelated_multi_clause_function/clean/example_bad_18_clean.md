```elixir
defmodule MyApp.NotificationDispatcher do
  @moduledoc """
  Central dispatcher responsible for sending outbound notifications
  across multiple notification channels (email, SMS, push).

  Each notification type carries its own delivery rules, retry logic,
  and audit requirements.
  """

  require Logger

  alias MyApp.Accounts.User
  alias MyApp.Mailer
  alias MyApp.SMS
  alias MyApp.PushNotifications
  alias MyApp.Audit
  alias MyApp.Repo

  defstruct [:type, :payload, :recipient_id, :inserted_at]

  # ---------------------------------------------------------------------------
  # Structs used as notification payloads
  # ---------------------------------------------------------------------------

  defmodule InvoiceAlert do
    @enforce_keys [:invoice_id, :amount_due, :due_date, :currency]
    defstruct [:invoice_id, :amount_due, :due_date, :currency, overdue: false]
  end

  defmodule ShipmentUpdate do
    @enforce_keys [:tracking_number, :carrier, :status]
    defstruct [:tracking_number, :carrier, :status, :estimated_delivery, :location]
  end

  defmodule PasswordResetRequest do
    @enforce_keys [:reset_token, :expires_at]
    defstruct [:reset_token, :expires_at, :ip_address, :user_agent]
  end

  @doc """
  Dispatches an invoice-overdue or payment-due alert to the customer via email.

  Overdue invoices additionally trigger an SMS reminder and an audit log entry.

  ## Parameters

    - `notification` – a `%MyApp.NotificationDispatcher{}` struct whose
      `payload` field holds an `%InvoiceAlert{}`.

  ## Examples

      iex> alias MyApp.NotificationDispatcher, as: ND
      iex> alias ND.InvoiceAlert
      iex> n = %ND{
      ...>   recipient_id: 42,
      ...>   payload: %InvoiceAlert{
      ...>     invoice_id: "INV-001",
      ...>     amount_due: 199_00,
      ...>     due_date: ~D[2024-06-30],
      ...>     currency: "USD",
      ...>     overdue: false
      ...>   }
      ...> }
      iex> ND.dispatch(n)
      :ok
  """
  def dispatch(%__MODULE__{payload: %InvoiceAlert{} = alert, recipient_id: uid}) do
    user = Repo.get!(User, uid)

    template =
      if alert.overdue do
        "invoice_overdue"
      else
        "invoice_due_soon"
      end

    :ok = Mailer.send(user.email, template, %{
      invoice_id:  alert.invoice_id,
      amount:      format_money(alert.amount_due, alert.currency),
      due_date:    Date.to_iso8601(alert.due_date)
    })

    if alert.overdue do
      :ok = SMS.send(user.phone, "Your invoice #{alert.invoice_id} is overdue. " <>
                                  "Please pay #{format_money(alert.amount_due, alert.currency)} immediately.")
      Audit.log(:invoice_overdue_notified, %{user_id: uid, invoice_id: alert.invoice_id})
    end

    Logger.info("[NotificationDispatcher] invoice alert sent", user_id: uid,
                                                                invoice_id: alert.invoice_id,
                                                                overdue: alert.overdue)
    :ok
  end

  # dispatch shipment status update via push notification and email
  def dispatch(%__MODULE__{payload: %ShipmentUpdate{} = update, recipient_id: uid}) do
    user = Repo.get!(User, uid)

    push_body = build_shipment_push_body(update)

    case PushNotifications.send(user.device_token, push_body) do
      {:ok, _receipt} ->
        Logger.info("[NotificationDispatcher] push sent for shipment",
                    user_id: uid, tracking: update.tracking_number)

      {:error, :no_device_token} ->
        Logger.warning("[NotificationDispatcher] no device token, falling back to email",
                       user_id: uid)

        Mailer.send(user.email, "shipment_update", %{
          tracking_number:    update.tracking_number,
          carrier:            update.carrier,
          status:             update.status,
          estimated_delivery: update.estimated_delivery,
          location:           update.location
        })
    end

    :ok
  end

  # dispatch password-reset link — high-urgency, email-only, no retries
  def dispatch(%__MODULE__{payload: %PasswordResetRequest{} = req, recipient_id: uid}) do
    user = Repo.get!(User, uid)

    if DateTime.before?(DateTime.utc_now(), req.expires_at) do
      reset_url = MyAppWeb.Router.Helpers.password_reset_url(
        MyAppWeb.Endpoint, :edit, req.reset_token
      )

      :ok = Mailer.send_immediate(user.email, "password_reset", %{
        reset_url:   reset_url,
        expires_at:  req.expires_at,
        ip_address:  req.ip_address,
        user_agent:  req.user_agent
      })

      Audit.log(:password_reset_email_sent, %{
        user_id:    uid,
        ip_address: req.ip_address
      })

      Logger.info("[NotificationDispatcher] password reset dispatched", user_id: uid)
      :ok
    else
      Logger.warning("[NotificationDispatcher] reset token expired, skipping dispatch",
                     user_id: uid)
      {:error, :token_expired}
    end
  end
  
  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp format_money(cents, currency) do
    major = div(cents, 100)
    minor = rem(cents, 100)
    "#{currency} #{major}.#{String.pad_leading(Integer.to_string(minor), 2, "0")}"
  end

  defp build_shipment_push_body(%ShipmentUpdate{status: "delivered"} = u) do
    %{title: "Your package arrived!", body: "Tracking #{u.tracking_number} delivered."}
  end

  defp build_shipment_push_body(%ShipmentUpdate{} = u) do
    %{title: "Shipment update", body: "#{u.tracking_number}: #{u.status} via #{u.carrier}."}
  end
end
```
