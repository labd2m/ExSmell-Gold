```elixir
defmodule Notifications.ContentBuilder do
  use GenServer

  @moduledoc """
  Renders notification content (subject, text body, HTML body) for email,
  push, and in-app notifications. Used by the notification dispatcher before
  handing messages to channel-specific delivery adapters.
  """

  @templates %{
    welcome: %{
      subject: "Welcome to {app_name}, {first_name}!",
      text: "Hi {first_name},\n\nWelcome to {app_name}. Your account is ready.\n\nGet started: {dashboard_url}\n\nThanks,\nThe {app_name} Team",
      html: "<p>Hi {first_name},</p><p>Welcome to <strong>{app_name}</strong>. Your account is ready.</p><p><a href=\"{dashboard_url}\">Get started</a></p>"
    },
    password_reset: %{
      subject: "Reset your {app_name} password",
      text: "Hi {first_name},\n\nClick the link below to reset your password. It expires in {expiry_minutes} minutes.\n\n{reset_url}\n\nIf you didn't request this, ignore this email.",
      html: "<p>Hi {first_name},</p><p>Click <a href=\"{reset_url}\">here</a> to reset your password. This link expires in {expiry_minutes} minutes.</p>"
    },
    order_confirmation: %{
      subject: "Order #{"{order_number}"} confirmed – {app_name}",
      text: "Hi {first_name},\n\nYour order {order_number} for {currency}{total} has been confirmed.\n\nEstimated delivery: {eta}\n\nTrack your order: {tracking_url}",
      html: "<p>Hi {first_name},</p><p>Your order <strong>{order_number}</strong> for <strong>{currency}{total}</strong> has been confirmed.</p><p>Estimated delivery: {eta}</p><p><a href=\"{tracking_url}\">Track your order</a></p>"
    },
    invoice_due: %{
      subject: "Invoice {invoice_number} due on {due_date}",
      text: "Hi {first_name},\n\nInvoice {invoice_number} for {currency}{amount} is due on {due_date}.\n\nPay now: {payment_url}",
      html: "<p>Hi {first_name},</p><p>Invoice <strong>{invoice_number}</strong> for <strong>{currency}{amount}</strong> is due on <strong>{due_date}</strong>.</p><p><a href=\"{payment_url}\">Pay now</a></p>"
    }
  }



  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, opts)
  end

  @doc """
  Builds the full notification content map for a given type and payload.
  """
  def build(pid, type, payload) do
    GenServer.call(pid, {:build, type, payload})
  end

  @doc """
  Returns only the notification subject line.
  """
  def subject(pid, type, payload) do
    GenServer.call(pid, {:subject, type, payload})
  end

  @doc """
  Returns only the plain-text body.
  """
  def body_text(pid, type, payload) do
    GenServer.call(pid, {:body_text, type, payload})
  end

  @doc """
  Returns only the HTML body.
  """
  def body_html(pid, type, payload) do
    GenServer.call(pid, {:body_html, type, payload})
  end

  ## GenServer Callbacks

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:build, type, payload}, _from, state) do
    result =
      case Map.get(@templates, type) do
        nil ->
          {:error, "Unknown notification type: #{type}"}

        template ->
          {:ok,
           %{
             type: type,
             subject: interpolate(template.subject, payload),
             text: interpolate(template.text, payload),
             html: interpolate(template.html, payload)
           }}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:subject, type, payload}, _from, state) do
    result = render_field(type, :subject, payload)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:body_text, type, payload}, _from, state) do
    result = render_field(type, :text, payload)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:body_html, type, payload}, _from, state) do
    result = render_field(type, :html, payload)
    {:reply, result, state}
  end

  defp render_field(type, field, payload) do
    case Map.get(@templates, type) do
      nil -> {:error, "Unknown notification type: #{type}"}
      template -> {:ok, interpolate(Map.get(template, field, ""), payload)}
    end
  end

  defp interpolate(template, payload) do
    Enum.reduce(payload, template, fn {key, value}, acc ->
      String.replace(acc, "{#{key}}", to_string(value))
    end)
  end
end
```
