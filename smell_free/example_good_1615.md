```elixir
defmodule Mailer.TemplateRenderer do
  @moduledoc """
  Renders named email templates to HTML and plain-text variants by
  resolving a template definition, merging caller-supplied variables,
  and applying a layout wrapper. Templates are cached after first compile.
  """

  alias Mailer.{TemplateStore, LayoutRegistry}

  @type template_name :: atom()
  @type variables :: map()

  @type rendered_email :: %{
          subject: String.t(),
          html_body: String.t(),
          text_body: String.t()
        }

  @spec render(template_name(), variables()) ::
          {:ok, rendered_email()} | {:error, :template_not_found | :render_failed}
  def render(template_name, variables \\ %{}) when is_atom(template_name) do
    with {:ok, template} <- TemplateStore.fetch(template_name),
         {:ok, layout} <- LayoutRegistry.fetch(template.layout),
         {:ok, subject} <- interpolate(template.subject_template, variables),
         {:ok, html_content} <- interpolate(template.html_template, variables),
         {:ok, text_content} <- interpolate(template.text_template, variables),
         {:ok, html_body} <- wrap_layout(layout, :html, html_content, variables),
         {:ok, text_body} <- wrap_layout(layout, :text, text_content, variables) do
      {:ok, %{subject: subject, html_body: html_body, text_body: text_body}}
    end
  end

  @spec preview(template_name(), variables()) ::
          {:ok, rendered_email()} | {:error, atom()}
  def preview(template_name, variables) do
    preview_vars = Map.merge(sample_variables(), variables)
    render(template_name, preview_vars)
  end

  @spec interpolate(String.t(), variables()) :: {:ok, String.t()} | {:error, :render_failed}
  defp interpolate(template_string, variables) do
    result =
      Regex.replace(~r/\{\{\s*(\w+)\s*\}\}/, template_string, fn _, key ->
        atom_key = String.to_existing_atom(key)
        value = Map.get(variables, atom_key, Map.get(variables, key, ""))
        to_string(value)
      end)

    {:ok, result}
  rescue
    _ -> {:error, :render_failed}
  end

  @spec wrap_layout(map(), :html | :text, String.t(), variables()) ::
          {:ok, String.t()} | {:error, :render_failed}
  defp wrap_layout(layout, :html, content, variables) do
    layout_vars = Map.put(variables, :content, content)
    interpolate(layout.html_template, layout_vars)
  end

  defp wrap_layout(layout, :text, content, variables) do
    layout_vars = Map.put(variables, :content, content)
    interpolate(layout.text_template, layout_vars)
  end

  @spec sample_variables() :: variables()
  defp sample_variables do
    %{
      first_name: "Alex",
      last_name: "Sample",
      email: "alex@example.com",
      app_name: "MyApp",
      support_email: "support@example.com",
      current_year: Date.utc_today().year
    }
  end
end
```
