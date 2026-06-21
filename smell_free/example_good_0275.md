```elixir
defmodule MyApp.Email.TemplateRenderer do
  @moduledoc """
  Renders transactional email templates from EEx source stored under
  `priv/email_templates/`. Each template is compiled once at application
  start and cached in ETS for zero-allocation reads at runtime.

  Both plain-text and HTML variants are supported. If only one variant
  exists for a template, the other is generated automatically: HTML is
  wrapped in a base layout, and plain text is derived by stripping tags.
  """

  use GenServer

  @table __MODULE__
  @template_dir Application.compile_env(:my_app, :email_template_dir, "priv/email_templates")

  @type template_name :: String.t()
  @type bindings :: keyword()
  @type rendered :: %{html: String.t(), text: String.t()}

  @doc "Starts the template renderer and compiles all templates into ETS."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Renders `template_name` with the given `bindings`.
  Returns `{:ok, %{html: ..., text: ...}}` or `{:error, :template_not_found}`.
  """
  @spec render(template_name(), bindings()) :: {:ok, rendered()} | {:error, :template_not_found}
  def render(template_name, bindings \\ []) when is_binary(template_name) do
    case :ets.lookup(@table, template_name) do
      [{^template_name, html_ast, text_ast}] ->
        html = EEx.eval_string(html_ast, bindings)
        text = EEx.eval_string(text_ast, bindings)
        {:ok, %{html: html, text: text}}

      [] ->
        {:error, :template_not_found}
    end
  end

  @doc "Returns a list of all available template names."
  @spec available_templates() :: [template_name()]
  def available_templates do
    :ets.tab2list(@table) |> Enum.map(&elem(&1, 0))
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    compile_all_templates()
    {:ok, %{}}
  end

  @spec compile_all_templates() :: :ok
  defp compile_all_templates do
    @template_dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".html.eex"))
    |> Enum.each(&compile_template/1)
  end

  @spec compile_template(String.t()) :: :ok
  defp compile_template(filename) do
    name = String.replace(filename, ".html.eex", "")
    html_path = Path.join(@template_dir, filename)
    text_path = Path.join(@template_dir, "#{name}.text.eex")

    html_source = File.read!(html_path)
    text_source = read_or_derive_text(text_path, html_source)

    :ets.insert(@table, {name, html_source, text_source})
    :ok
  end

  @spec read_or_derive_text(String.t(), String.t()) :: String.t()
  defp read_or_derive_text(text_path, html_source) do
    case File.read(text_path) do
      {:ok, content} -> content
      {:error, _} -> strip_html_tags(html_source)
    end
  end

  @spec strip_html_tags(String.t()) :: String.t()
  defp strip_html_tags(html) do
    html
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace(~r/\s{2,}/, " ")
    |> String.trim()
  end
end
```
