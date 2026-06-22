**File:** `example_good_1169.md`

```elixir
defmodule Mailer.Template do
  @moduledoc "Represents a rendered email template with subject and body."

  @enforce_keys [:subject, :html_body, :text_body]
  defstruct [:subject, :html_body, :text_body, :preheader]

  @type t :: %__MODULE__{
          subject: String.t(),
          html_body: String.t(),
          text_body: String.t(),
          preheader: String.t() | nil
        }
end

defmodule Mailer.TemplateRenderer do
  @moduledoc """
  Renders named email templates by combining a base layout with
  template-specific content blocks and variable interpolation.
  """

  alias Mailer.Template

  @type assigns :: %{atom() => term()}
  @type render_result :: {:ok, Template.t()} | {:error, {:unknown_template, String.t()}}

  @spec render(String.t(), assigns()) :: render_result()
  def render(template_name, assigns) when is_binary(template_name) and is_map(assigns) do
    case fetch_template_module(template_name) do
      {:ok, mod} ->
        subject = mod.subject(assigns)
        html_content = mod.html_content(assigns)
        text_content = mod.text_content(assigns)

        {:ok, %Template{
          subject: subject,
          html_body: wrap_html_layout(html_content, assigns),
          text_body: wrap_text_layout(text_content, assigns),
          preheader: Map.get(assigns, :preheader)
        }}

      :error ->
        {:error, {:unknown_template, template_name}}
    end
  end

  defp fetch_template_module(name) do
    known = %{
      "welcome" => Mailer.Templates.Welcome,
      "password_reset" => Mailer.Templates.PasswordReset,
      "invoice_ready" => Mailer.Templates.InvoiceReady
    }

    Map.fetch(known, name)
  end

  defp wrap_html_layout(content, assigns) do
    app_name = Map.get(assigns, :app_name, "App")

    """
    <!DOCTYPE html>
    <html>
    <head><meta charset="UTF-8"><title>#{app_name}</title></head>
    <body style="font-family:sans-serif;max-width:600px;margin:0 auto;">
    #{content}
    <footer style="margin-top:32px;font-size:12px;color:#888;">
      You received this email from #{app_name}.
    </footer>
    </body>
    </html>
    """
  end

  defp wrap_text_layout(content, assigns) do
    app_name = Map.get(assigns, :app_name, "App")
    "#{content}\n\n---\nYou received this email from #{app_name}."
  end
end

defmodule Mailer.Templates.Welcome do
  @moduledoc "Email template sent when a new user completes registration."

  @spec subject(map()) :: String.t()
  def subject(%{app_name: app_name}), do: "Welcome to #{app_name}!"
  def subject(_assigns), do: "Welcome!"

  @spec html_content(map()) :: String.t()
  def html_content(assigns) do
    name = Map.get(assigns, :user_name, "there")
    """
    <h1>Welcome, #{name}!</h1>
    <p>Your account has been created successfully.</p>
    <p><a href="#{Map.get(assigns, :login_url, "#")}">Log in to get started</a></p>
    """
  end

  @spec text_content(map()) :: String.t()
  def text_content(assigns) do
    name = Map.get(assigns, :user_name, "there")
    login_url = Map.get(assigns, :login_url, "")
    "Welcome, #{name}!\n\nYour account has been created.\nLog in here: #{login_url}"
  end
end

defmodule Mailer.Templates.PasswordReset do
  @moduledoc "Email template sent to initiate a password reset flow."

  @spec subject(map()) :: String.t()
  def subject(_assigns), do: "Reset your password"

  @spec html_content(map()) :: String.t()
  def html_content(assigns) do
    reset_url = Map.get(assigns, :reset_url, "#")
    expiry_minutes = Map.get(assigns, :expiry_minutes, 30)
    """
    <h1>Password Reset Request</h1>
    <p>Click the link below to reset your password. This link expires in #{expiry_minutes} minutes.</p>
    <p><a href="#{reset_url}">Reset Password</a></p>
    <p>If you did not request a password reset, you can safely ignore this email.</p>
    """
  end

  @spec text_content(map()) :: String.t()
  def text_content(assigns) do
    reset_url = Map.get(assigns, :reset_url, "")
    expiry_minutes = Map.get(assigns, :expiry_minutes, 30)
    "Reset your password here (expires in #{expiry_minutes} min): #{reset_url}\n\nIgnore this if you did not request it."
  end
end

defmodule Mailer.Templates.InvoiceReady do
  @moduledoc "Email template sent when a new invoice is available for a customer."

  @spec subject(map()) :: String.t()
  def subject(%{invoice_number: n}), do: "Your invoice ##{n} is ready"
  def subject(_assigns), do: "Your invoice is ready"

  @spec html_content(map()) :: String.t()
  def html_content(assigns) do
    amount = Map.get(assigns, :amount_formatted, "$0.00")
    due_date = Map.get(assigns, :due_date, "N/A")
    invoice_url = Map.get(assigns, :invoice_url, "#")
    """
    <h1>Invoice Ready</h1>
    <p>Amount due: <strong>#{amount}</strong></p>
    <p>Due date: #{due_date}</p>
    <p><a href="#{invoice_url}">View Invoice</a></p>
    """
  end

  @spec text_content(map()) :: String.t()
  def text_content(assigns) do
    amount = Map.get(assigns, :amount_formatted, "$0.00")
    due_date = Map.get(assigns, :due_date, "N/A")
    url = Map.get(assigns, :invoice_url, "")
    "Amount due: #{amount}\nDue: #{due_date}\nView invoice: #{url}"
  end
end
```
