```elixir
defmodule StringUtils do
  def truncate(str, max) when byte_size(str) > max do
    String.slice(str, 0, max - 3) <> "..."
  end
  def truncate(str, _max), do: str

  def slugify(str) do
    str
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s-]/, "")
    |> String.replace(~r/[\s]+/, "-")
    |> String.trim("-")
  end

  def strip_html(str), do: String.replace(str, ~r/<[^>]+>/, "")
end

defmodule TemplateEngine do
  defmacro __using__(_opts) do
    quote do
      import StringUtils

      def render(template, assigns) do
        Enum.reduce(assigns, template, fn {key, value}, acc ->
          String.replace(acc, "{{#{key}}}", to_string(value))
        end)
      end

      def render_subject(subject_template, assigns) do
        result = render(subject_template, assigns)
        truncate(result, 78)
      end

      def render_preview(body_template, assigns) do
        body = render(body_template, assigns)
        body |> strip_html() |> truncate(140)
      end
    end
  end
end

defmodule NotificationDispatcher do
  use TemplateEngine

  @channels [:email, :sms, :push]

  @templates %{
    welcome:        {"Welcome to {{app}}, {{name}}!", "Hi {{name}},\nYour account is ready."},
    password_reset: {"Reset your password", "Click <a href='{{link}}'>here</a> to reset."},
    order_shipped:  {"Your order {{order_id}} shipped!", "Estimated delivery: {{eta}}."},
    invoice_ready:  {"Invoice #{{invoice_id}} available", "Your invoice for {{amount}} is ready."}
  }

  def dispatch(notification, opts \\ []) do
    channel  = Keyword.get(opts, :channel, :email)
    template = Map.fetch!(@templates, notification.type)

    unless channel in @channels do
      raise ArgumentError, "Unknown channel: #{channel}"
    end

    envelope = build_envelope(notification, template, channel)
    deliver(envelope, channel)
  end

  def render_body(type, assigns) do
    {_subj, body_tpl} = Map.fetch!(@templates, type)
    body = render(body_tpl, assigns)
    strip_html(body)
  end

  def build_envelope(notification, {subj_tpl, body_tpl}, channel) do
    assigns = notification.assigns

    %{
      channel:   channel,
      recipient: notification.recipient,
      subject:   render_subject(subj_tpl, assigns),
      body:      render(body_tpl, assigns),
      preview:   render_preview(body_tpl, assigns),
      ref:       slugify("#{notification.type}-#{notification.recipient.id}"),
      sent_at:   DateTime.utc_now()
    }
  end

  defp deliver(envelope, :email) do
    {:ok, Map.put(envelope, :message_id, "email-#{:erlang.unique_integer([:positive])}")}
  end
  defp deliver(envelope, :sms) do
    body = truncate(envelope.body, 160)
    {:ok, Map.merge(envelope, %{body: body, message_id: "sms-#{:erlang.unique_integer([:positive])}"})}
  end
  defp deliver(envelope, :push) do
    {:ok, Map.put(envelope, :message_id, "push-#{:erlang.unique_integer([:positive])}")}
  end

  def batch_dispatch(notifications, opts \\ []) do
    Enum.map(notifications, fn n ->
      case dispatch(n, opts) do
        {:ok, env} -> {:ok, env}
        err        -> {:error, {n.type, err}}
      end
    end)
  end
end
```
