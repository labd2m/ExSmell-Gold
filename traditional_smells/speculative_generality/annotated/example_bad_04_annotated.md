# Example Bad 04 — Annotated

## Metadata

- **Smell Name**: Speculative Generality
- **Expected Smell Location**: `Notifications.TemplateCache` (module definition)
- **Affected Function(s)**: entire `Notifications.TemplateCache` module
- **Explanation**: `Notifications.TemplateCache` was defined speculatively to cache
  compiled email templates in memory and reduce repeated disk reads. The main module
  `Notifications.EmailDispatcher` never references it — all template loading is done
  directly via `File.read!/1`. The `TemplateCache` module exists solely as unused
  speculative infrastructure, adding dead code that must be maintained.

## Code

```elixir
defmodule Notifications.EmailDispatcher do
  @moduledoc """
  Dispatches transactional email notifications to users and operators.
  Handles welcome emails, password resets, invoice delivery, and alerts.
  """

  alias Notifications.{DeliveryLog, EmailQueue}
  alias Notifications.Repo

  @template_dir    "priv/email_templates"
  @max_retries     3
  @retry_delay_ms  2_000

  def dispatch_welcome(user) do
    body = render_template("welcome.html", %{name: user.name, email: user.email})
    enqueue(:welcome, user.email, "Welcome to the Platform!", body)
  end

  def dispatch_password_reset(user, reset_token) do
    reset_url = "https://app.example.com/reset?token=#{reset_token}"
    body      = render_template("password_reset.html", %{name: user.name, url: reset_url})
    enqueue(:password_reset, user.email, "Password Reset Request", body)
  end

  def dispatch_invoice(customer_email, invoice) do
    body = render_template("invoice.html", %{
      invoice_id:  invoice.id,
      total:       invoice.total,
      due_date:    invoice.due_date,
      line_items:  invoice.line_items
    })
    enqueue(:invoice, customer_email, "Your Invoice ##{invoice.id}", body)
  end

  def dispatch_alert(admin_email, alert_message) do
    body = render_template("alert.html", %{message: alert_message, ts: DateTime.utc_now()})
    enqueue(:alert, admin_email, "[ALERT] System Notification", body)
  end

  def retry_failed_deliveries do
    DeliveryLog
    |> Repo.all()
    |> Enum.filter(&(&1.status == :failed and &1.attempts < @max_retries))
    |> Enum.each(fn log ->
      Process.sleep(@retry_delay_ms)
      EmailQueue.push(log.payload)

      log
      |> DeliveryLog.changeset(%{attempts: log.attempts + 1, last_retry: DateTime.utc_now()})
      |> Repo.update()
    end)
  end

  def delivery_stats do
    logs = Repo.all(DeliveryLog)

    %{
      total:      length(logs),
      delivered:  Enum.count(logs, &(&1.status == :delivered)),
      failed:     Enum.count(logs, &(&1.status == :failed)),
      pending:    Enum.count(logs, &(&1.status == :pending))
    }
  end

  # --- Private ---

  defp render_template(template_name, bindings) do
    path    = Path.join(@template_dir, template_name)
    content = File.read!(path)

    Enum.reduce(bindings, content, fn {key, val}, acc ->
      String.replace(acc, "{{#{key}}}", to_string(val))
    end)
  end

  defp enqueue(type, to, subject, body) do
    payload = %{type: type, to: to, subject: subject, body: body, sent_at: nil}

    case EmailQueue.push(payload) do
      :ok ->
        Repo.insert!(%DeliveryLog{
          type:     type,
          to:       to,
          subject:  subject,
          status:   :pending,
          attempts: 0,
          payload:  payload
        })
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end

# VALIDATION: SMELL START - Speculative Generality
# VALIDATION: This is a smell because `Notifications.TemplateCache` is a module
# defined speculatively to cache parsed email templates in an ETS table and avoid
# repeated file reads. The module is fully implemented but is never referenced or
# called anywhere—`Notifications.EmailDispatcher` reads templates directly via
# `File.read!/1` without ever consulting this cache. The entire module is dead code.
defmodule Notifications.TemplateCache do
  @moduledoc """
  In-memory cache for compiled email templates backed by an ETS table.
  Intended to reduce repeated disk reads for high-volume notification dispatch.
  """

  @table_name :template_cache

  def start do
    :ets.new(@table_name, [:set, :public, :named_table])
    :ok
  end

  def get(template_name) do
    case :ets.lookup(@table_name, template_name) do
      [{^template_name, content}] -> {:ok, content}
      []                          -> :miss
    end
  end

  def put(template_name, content) do
    :ets.insert(@table_name, {template_name, content})
    :ok
  end

  def invalidate(template_name) do
    :ets.delete(@table_name, template_name)
    :ok
  end

  def clear_all do
    :ets.delete_all_objects(@table_name)
    :ok
  end
end
# VALIDATION: SMELL END
```
