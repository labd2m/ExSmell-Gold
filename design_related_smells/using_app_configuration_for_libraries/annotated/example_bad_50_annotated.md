# Code Smell Example – Annotated

- **Smell name:** Using App Configuration for libraries
- **Expected smell location:** `TemplateRenderer.render/2`
- **Affected function(s):** `render/2`, `render_layout/3`
- **Short explanation:** The library reads `:template_dir`, `:layout_file`, and `:cache_templates` from the global `Application Environment` instead of accepting them as options. A dependent application that wants to render both user-facing HTML from one template directory and admin emails from another cannot do so without changing global configuration, breaking the library's usefulness as a generic renderer.

```elixir
defmodule TemplateRenderer do
  @moduledoc """
  A file-based template rendering library that supports EEx templates
  with optional layout wrapping, template caching, and partial includes.
  Used for HTML email generation, PDF report rendering, and HTML page assembly.

  Configuration (config/config.exs):

      config :template_renderer,
        template_dir: "priv/templates",
        layout_file: "layout.html.eex",
        cache_templates: false
  """

  require Logger
  use Agent

  @cache_agent __MODULE__.Cache

  @doc """
  Starts the template cache agent. Call during application startup when
  `cache_templates: true` is configured.
  """
  @spec start_link(any()) :: Agent.on_start()
  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{} end, name: @cache_agent)
  end

  @doc """
  Renders a named template with the given assigns map.
  Reads the template directory and caching preference from application config.

  Returns `{:ok, rendered_html}` or `{:error, reason}`.
  """
  @spec render(String.t(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def render(template_name, assigns \\ %{}) when is_binary(template_name) and is_map(assigns) do
    # VALIDATION: SMELL START - Using App Configuration for libraries
    # VALIDATION: This is a smell because the library reads :template_dir and
    # :cache_templates from the global Application Environment rather than
    # accepting them as keyword arguments. An application that renders user-facing
    # transactional emails from "priv/templates/emails" and administrative reports
    # from "priv/templates/reports" cannot call render/2 with different base
    # directories. Both usages are forced to share the single global template_dir,
    # making it impossible to use this library across multiple template namespaces
    # without a runtime config swap.
    template_dir = Application.fetch_env!(:template_renderer, :template_dir)
    cache = Application.fetch_env!(:template_renderer, :cache_templates)
    # VALIDATION: SMELL END

    path = Path.join([template_dir, template_name])

    with {:ok, source} <- load_template(path, cache) do
      try do
        rendered = EEx.eval_string(source, assigns: assigns)
        {:ok, rendered}
      rescue
        e in EEx.SyntaxError ->
          {:error, "Template syntax error in #{template_name}: #{Exception.message(e)}"}

        e ->
          {:error, "Render error in #{template_name}: #{Exception.message(e)}"}
      end
    end
  end

  @doc """
  Renders a template and wraps it in the configured layout file.
  The inner content is passed to the layout as `@inner_content`.
  """
  @spec render_layout(String.t(), map(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def render_layout(template_name, assigns, layout_assigns \\ %{}) do
    layout_file = Application.fetch_env!(:template_renderer, :layout_file)
    template_dir = Application.fetch_env!(:template_renderer, :template_dir)

    with {:ok, inner_html} <- render(template_name, assigns) do
      layout_assigns_with_content = Map.put(layout_assigns, :inner_content, inner_html)
      layout_path = Path.join([template_dir, layout_file])

      case load_template(layout_path, false) do
        {:ok, layout_source} ->
          try do
            rendered = EEx.eval_string(layout_source, assigns: layout_assigns_with_content)
            {:ok, rendered}
          rescue
            e -> {:error, "Layout render error: #{Exception.message(e)}"}
          end

        {:error, _} = err ->
          err
      end
    end
  end

  @doc """
  Clears the in-memory template cache.
  """
  @spec clear_cache() :: :ok
  def clear_cache do
    if Process.whereis(@cache_agent) do
      Agent.update(@cache_agent, fn _ -> %{} end)
    end

    :ok
  end

  @doc """
  Lists all available template names in the configured template directory.
  """
  @spec list_templates() :: {:ok, list(String.t())} | {:error, String.t()}
  def list_templates do
    template_dir = Application.fetch_env!(:template_renderer, :template_dir)

    case File.ls(template_dir) do
      {:ok, files} ->
        templates = Enum.filter(files, &String.ends_with?(&1, ".eex"))
        {:ok, templates}

      {:error, reason} ->
        {:error, "Could not list templates: #{:file.format_error(reason)}"}
    end
  end

  # --- Private helpers ---

  defp load_template(path, _cache = false) do
    case File.read(path) do
      {:ok, source} -> {:ok, source}
      {:error, reason} -> {:error, "Cannot read template '#{path}': #{:file.format_error(reason)}"}
    end
  end

  defp load_template(path, _cache = true) do
    if Process.whereis(@cache_agent) do
      case Agent.get(@cache_agent, &Map.fetch(&1, path)) do
        {:ok, cached} ->
          Logger.debug("[TemplateRenderer] Cache hit: #{path}")
          {:ok, cached}

        :error ->
          with {:ok, source} <- load_template(path, false) do
            Agent.update(@cache_agent, &Map.put(&1, path, source))
            {:ok, source}
          end
      end
    else
      load_template(path, false)
    end
  end
end
```
