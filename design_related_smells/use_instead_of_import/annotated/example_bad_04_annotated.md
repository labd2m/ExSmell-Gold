# example_bad_04_annotated.md

## Metadata

- **Smell Name:** "Use" instead of "import"
- **Expected Smell Location:** `Notifications.EmailComposer` module, `use Notifications.TemplateHelpers` directive
- **Affected Function(s):** Module-level directive (affects the entire `Notifications.EmailComposer` module)
- **Short Explanation:** `Notifications.EmailComposer` uses `use Notifications.TemplateHelpers` to gain access to template-rendering functions. The `__using__/1` macro silently injects `import Notifications.HtmlUtils` into the caller, making functions from `HtmlUtils` available in `EmailComposer` without any explicit declaration. Since only the template functions are actually needed, `import Notifications.TemplateHelpers` would be the correct, transparent alternative.

## Code

```elixir
defmodule Notifications.HtmlUtils do
  @moduledoc """
  HTML escaping and inline-style helpers for email rendering.
  """

  def escape_html(nil), do: ""

  def escape_html(string) when is_binary(string) do
    string
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  def wrap_bold(text),   do: "<strong>#{escape_html(text)}</strong>"
  def wrap_italic(text), do: "<em>#{escape_html(text)}</em>"

  def inline_style(props) do
    props
    |> Enum.map(fn {k, v} -> "#{k}: #{v}" end)
    |> Enum.join("; ")
  end
end

defmodule Notifications.TemplateHelpers do
  @moduledoc """
  Email template composition utilities, shared across notification modules via `use`.
  """

  defmacro __using__(_opts) do
    quote do
      import Notifications.HtmlUtils  # propagates HTML utility dependency into caller

      def greeting(recipient_name) do
        "<p>Hello, #{escape_html(recipient_name)},</p>"
      end

      def action_button(label, url, color \\ "#4f46e5") do
        style =
          inline_style([
            {"display", "inline-block"},
            {"background-color", color},
            {"color", "#ffffff"},
            {"padding", "12px 24px"},
            {"border-radius", "4px"},
            {"text-decoration", "none"},
            {"font-weight", "bold"}
          ])

        "<a href=\"#{escape_html(url)}\" style=\"#{style}\">#{escape_html(label)}</a>"
      end

      def signature(sender_name, sender_title) do
        """
        <p>Best regards,<br>
        #{wrap_bold(sender_name)}<br>
        #{escape_html(sender_title)}</p>
        """
      end

      def html_wrapper(title, body_html) do
        """
        <!DOCTYPE html>
        <html>
          <head><meta charset="UTF-8"><title>#{escape_html(title)}</title></head>
          <body style="font-family: sans-serif; max-width: 600px; margin: 0 auto;">
            #{body_html}
          </body>
        </html>
        """
      end
    end
  end
end

defmodule Notifications.EmailComposer do
  @moduledoc """
  Composes transactional email messages for the notification system.
  Supports account verification, password reset, and invoice delivery emails.
  """

  # VALIDATION: SMELL START - "Use" instead of "import"
  # VALIDATION: This is a smell because `use Notifications.TemplateHelpers`
  # VALIDATION: triggers `__using__/1`, which injects `import Notifications.HtmlUtils`
  # VALIDATION: into `EmailComposer`. This means that `escape_html/1`,
  # VALIDATION: `wrap_bold/1`, and `inline_style/1` land in this module's
  # VALIDATION: namespace without any explicit declaration. Only the template
  # VALIDATION: helpers are needed; `import Notifications.TemplateHelpers` would
  # VALIDATION: make that intent visible and prevent the transitive coupling.
  use Notifications.TemplateHelpers
  # VALIDATION: SMELL END

  @sender_name  "Acme Platform"
  @sender_title "Automated Notification Service"
  @base_url     "https://app.acme.io"

  def verification_email(user) do
    link    = "#{@base_url}/verify?token=#{user.verification_token}"
    subject = "Please verify your email address"

    body =
      """
      #{greeting(user.name)}
      <p>Thank you for registering. Please verify your email address by clicking the button below.</p>
      #{action_button("Verify Email", link)}
      <p>This link expires in 24 hours. If you did not create an account, you can safely ignore this email.</p>
      #{signature(@sender_name, @sender_title)}
      """

    %{
      to:      user.email,
      subject: subject,
      html:    html_wrapper(subject, body),
      text:    "Verify your email: #{link}"
    }
  end

  def password_reset_email(user, token) do
    link    = "#{@base_url}/reset-password?token=#{token}"
    subject = "Reset your password"

    body =
      """
      #{greeting(user.name)}
      <p>We received a request to reset your password. Click the button below to choose a new one.</p>
      #{action_button("Reset Password", link, "#dc2626")}
      <p>This link is valid for 1 hour. If you did not request this, please contact support immediately.</p>
      #{signature(@sender_name, @sender_title)}
      """

    %{
      to:      user.email,
      subject: subject,
      html:    html_wrapper(subject, body),
      text:    "Reset your password: #{link}"
    }
  end

  def invoice_email(user, invoice_number, amount) do
    subject = "Your invoice #{invoice_number} is ready"

    body =
      """
      #{greeting(user.name)}
      <p>Your invoice #{wrap_bold(invoice_number)} for #{wrap_bold(amount)} is now available.</p>
      #{action_button("View Invoice", "#{@base_url}/invoices/#{invoice_number}")}
      #{signature(@sender_name, @sender_title)}
      """

    %{
      to:      user.email,
      subject: subject,
      html:    html_wrapper(subject, body),
      text:    "View invoice #{invoice_number}: #{@base_url}/invoices/#{invoice_number}"
    }
  end
end
```
