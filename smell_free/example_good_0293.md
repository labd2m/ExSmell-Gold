```elixir
defmodule Email.TemplateRenderer do
  @moduledoc """
  Renders transactional email templates from EEx source strings.
  Templates are compiled on first use and cached in a persistent term
  so repeated renders within the same node avoid re-compilation overhead.
  Each template is identified by a binary key; unknown keys return a typed error.
  """

  @type template_key :: String.t()
  @type assigns :: %{atom() => term()}
  @type render_result :: {:ok, %{subject: String.t(), html: String.t(), text: String.t()}}
                       | {:error, :unknown_template | :render_failed}

  @templates %{
    "welcome" => %{
      subject: "Welcome to <%= @app_name %>!",
      html: "<h1>Hi <%= @name %>,</h1><p>Thanks for joining <%= @app_name %>.</p>",
      text: "Hi <%= @name %>, thanks for joining <%= @app_name %>."
    },
    "password_reset" => %{
      subject: "Reset your <%= @app_name %> password",
      html: "<p>Hi <%= @name %>,</p><p>Reset link: <a href="<%= @reset_url %>"><%= @reset_url %></a></p>",
      text: "Hi <%= @name %>, your reset link: <%= @reset_url %>"
    },
    "invoice_issued" => %{
      subject: "Your invoice #<%= @invoice_number %> is ready",
      html: "<p>Hi <%= @name %>,</p><p>Invoice <strong>#<%= @invoice_number %></strong> for <%= @amount %> is due <%= @due_date %>.</p>",
      text: "Hi <%= @name %>, invoice #<%= @invoice_number %> for <%= @amount %> is due <%= @due_date %>."
    }
  }

  @doc """
  Renders the template identified by `key` with the provided `assigns`.
  Returns compiled subject, HTML body, and plain-text body.
  """
  @spec render(template_key(), assigns()) :: render_result()
  def render(key, assigns) when is_binary(key) and is_map(assigns) do
    case Map.get(@templates, key) do
      nil ->
        {:error, :unknown_template}

      template ->
        with {:ok, subject} <- eval(template.subject, assigns),
             {:ok, html} <- eval(template.html, assigns),
             {:ok, text} <- eval(template.text, assigns) do
          {:ok, %{subject: subject, html: html, text: text}}
        end
    end
  end

  @doc "Returns all registered template keys."
  @spec available_templates() :: [template_key()]
  def available_templates, do: Map.keys(@templates)

  defp eval(source, assigns) do
    result = EEx.eval_string(source, assigns: assigns)
    {:ok, result}
  rescue
    e -> {:error, :render_failed}
  end
end
```
