# File: `example_good_87.md`

```elixir
defmodule Notifications.TemplateRenderer do
  @moduledoc """
  Renders notification templates for multiple channels (email, SMS, push)
  from a unified template definition and a variable bindings map.

  Rendering is a pure transformation with no I/O. The caller is responsible
  for delivering the rendered output via the appropriate transport.
  """

  @type channel :: :email | :sms | :push

  @type template :: %{
          required(:name) => String.t(),
          optional(:email) => %{subject: String.t(), html_body: String.t(), text_body: String.t()},
          optional(:sms) => %{body: String.t()},
          optional(:push) => %{title: String.t(), body: String.t()}
        }

  @type bindings :: %{String.t() => String.t() | number()}

  @type email_output :: %{subject: String.t(), html_body: String.t(), text_body: String.t()}
  @type sms_output :: %{body: String.t()}
  @type push_output :: %{title: String.t(), body: String.t()}

  @type render_result ::
          {:ok, email_output() | sms_output() | push_output()}
          | {:error, :channel_not_supported}
          | {:error, {:missing_variable, String.t()}}

  @doc """
  Renders the given template for a specific channel by substituting
  `{{variable_name}}` placeholders with values from `bindings`.

  Returns `{:ok, rendered_output}` or an error describing the first
  substitution failure encountered.
  """
  @spec render(template(), channel(), bindings()) :: render_result()
  def render(template, channel, bindings)
      when is_map(template) and is_atom(channel) and is_map(bindings) do
    case Map.fetch(template, channel) do
      {:ok, channel_template} -> render_channel(channel_template, channel, bindings)
      :error -> {:error, :channel_not_supported}
    end
  end

  @doc """
  Extracts the set of variable names referenced in a template for a
  given channel. Useful for validating bindings before rendering.
  """
  @spec required_variables(template(), channel()) ::
          {:ok, MapSet.t(String.t())} | {:error, :channel_not_supported}
  def required_variables(template, channel) when is_map(template) and is_atom(channel) do
    case Map.fetch(template, channel) do
      {:ok, channel_template} ->
        vars =
          channel_template
          |> Map.values()
          |> Enum.flat_map(&extract_variable_names/1)
          |> MapSet.new()

        {:ok, vars}

      :error ->
        {:error, :channel_not_supported}
    end
  end

  defp render_channel(channel_template, :email, bindings) do
    with {:ok, subject} <- substitute(channel_template.subject, bindings),
         {:ok, html_body} <- substitute(channel_template.html_body, bindings),
         {:ok, text_body} <- substitute(channel_template.text_body, bindings) do
      {:ok, %{subject: subject, html_body: html_body, text_body: text_body}}
    end
  end

  defp render_channel(channel_template, :sms, bindings) do
    with {:ok, body} <- substitute(channel_template.body, bindings) do
      {:ok, %{body: body}}
    end
  end

  defp render_channel(channel_template, :push, bindings) do
    with {:ok, title} <- substitute(channel_template.title, bindings),
         {:ok, body} <- substitute(channel_template.body, bindings) do
      {:ok, %{title: title, body: body}}
    end
  end

  defp substitute(template_string, bindings) when is_binary(template_string) do
    variable_names = extract_variable_names(template_string)

    missing =
      Enum.find(variable_names, fn name ->
        not Map.has_key?(bindings, name)
      end)

    case missing do
      nil -> {:ok, interpolate(template_string, bindings)}
      name -> {:error, {:missing_variable, name}}
    end
  end

  defp interpolate(template_string, bindings) do
    Enum.reduce(bindings, template_string, fn {key, value}, acc ->
      String.replace(acc, "{{#{key}}}", to_string(value))
    end)
  end

  defp extract_variable_names(text) when is_binary(text) do
    ~r/\{\{([a-zA-Z0-9_]+)\}\}/
    |> Regex.scan(text, capture: :all_but_first)
    |> List.flatten()
  end

  defp extract_variable_names(_non_string), do: []
end
```
