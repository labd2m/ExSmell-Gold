```elixir
defmodule Notifications.TemplateEngine do
  @moduledoc """
  Resolves and renders notification templates for email, push, and SMS channels.
  Templates are keyed by event type and locale and loaded from the app priv directory.
  """

  @templates_base_path Application.compile_env(:my_app, :templates_path, "priv/templates")
  @default_locale "en"
  @supported_channels ~w(email push sms)a

  def render(event_type, channel, assigns, opts \\ []) do
    locale = Keyword.get(opts, :locale, @default_locale)

    unless channel in @supported_channels do
      raise ArgumentError, "Unsupported notification channel: #{inspect(channel)}"
    end

    with {:ok, key} <- resolve_template_key(event_type),
         {:ok, template} <- load_template(key, channel, locale),
         {:ok, rendered} <- apply_assigns(template, assigns) do
      {:ok, rendered}
    end
  end

  def resolve_template_key(event_type) do
    key =
      event_type
      |> to_string()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_]/, "_")
      |> String.trim("_")

    if key == "" do
      {:error, :empty_template_key}
    else
      {:ok, key}
    end
  end

  def load_template(key, channel, locale) do
    path = Path.join([@templates_base_path, to_string(channel), locale, "#{key}.html.eex"])

    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:error, {:template_not_found, key, channel, locale}}
      {:error, reason} -> {:error, {:template_read_error, reason}}
    end
  end

  def apply_assigns(template, assigns) when is_binary(template) and is_map(assigns) do
    try do
      rendered = EEx.eval_string(template, assigns: assigns)
      {:ok, rendered}
    rescue
      e in EEx.SyntaxError -> {:error, {:template_syntax_error, Exception.message(e)}}
      e -> {:error, {:template_render_error, Exception.message(e)}}
    end
  end

  def list_available_templates(channel) when channel in @supported_channels do
    dir = Path.join([@templates_base_path, to_string(channel)])

    case File.ls(dir) do
      {:ok, files} ->
        keys =
          files
          |> Enum.filter(&String.ends_with?(&1, ".html.eex"))
          |> Enum.map(&String.replace(&1, ".html.eex", ""))

        {:ok, keys}

      {:error, reason} ->
        {:error, {:cannot_list_templates, reason}}
    end
  end

  def preview_template(event_type, channel, sample_assigns \\ %{}) do
    with {:ok, key} <- resolve_template_key(event_type),
         {:ok, template} <- load_template(key, channel, @default_locale) do
      apply_assigns(template, sample_assigns)
    end
  end
end
```
