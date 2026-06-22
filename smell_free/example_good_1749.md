**File:** `example_good_1749.md`

```elixir
defmodule DocumentRenderer.Document do
  @moduledoc "Represents a structured document ready for rendering."

  @enforce_keys [:id, :title, :sections, :format]
  defstruct [:id, :title, :sections, :format, :metadata]

  @type format :: :html | :markdown | :plain_text
  @type section :: %{heading: String.t() | nil, body: String.t()}
  @type t :: %__MODULE__{
          id: String.t(),
          title: String.t(),
          sections: [section()],
          format: format(),
          metadata: map() | nil
        }
end

defmodule DocumentRenderer.Renderer do
  @moduledoc """
  Behaviour contract for document format renderers.
  Implement this to add support for a new output format.
  """

  alias DocumentRenderer.Document

  @doc "Renders a document to a string in the target format."
  @callback render(Document.t()) :: {:ok, String.t()} | {:error, term()}

  @doc "Returns the MIME type string for the rendered output."
  @callback mime_type() :: String.t()
end

defmodule DocumentRenderer.HtmlRenderer do
  @moduledoc "Renders documents as HTML with semantic heading and paragraph tags."

  @behaviour DocumentRenderer.Renderer

  alias DocumentRenderer.Document

  @impl DocumentRenderer.Renderer
  def mime_type, do: "text/html"

  @impl DocumentRenderer.Renderer
  def render(%Document{title: title, sections: sections}) do
    body =
      sections
      |> Enum.map(&render_section/1)
      |> Enum.join("\n")

    html = """
    <!DOCTYPE html>
    <html>
    <head><title>#{escape(title)}</title></head>
    <body>
    <h1>#{escape(title)}</h1>
    #{body}
    </body>
    </html>
    """

    {:ok, String.trim(html)}
  end

  defp render_section(%{heading: nil, body: body}), do: "<p>#{escape(body)}</p>"
  defp render_section(%{heading: heading, body: body}) do
    "<h2>#{escape(heading)}</h2>\n<p>#{escape(body)}</p>"
  end

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end

defmodule DocumentRenderer.MarkdownRenderer do
  @moduledoc "Renders documents as Markdown with ATX headings."

  @behaviour DocumentRenderer.Renderer

  alias DocumentRenderer.Document

  @impl DocumentRenderer.Renderer
  def mime_type, do: "text/markdown"

  @impl DocumentRenderer.Renderer
  def render(%Document{title: title, sections: sections}) do
    body =
      sections
      |> Enum.map(&render_section/1)
      |> Enum.join("\n\n")

    {:ok, "# #{title}\n\n#{body}"}
  end

  defp render_section(%{heading: nil, body: body}), do: body
  defp render_section(%{heading: heading, body: body}), do: "## #{heading}\n\n#{body}"
end

defmodule DocumentRenderer.PlainTextRenderer do
  @moduledoc "Renders documents as plain text with simple line separators."

  @behaviour DocumentRenderer.Renderer

  alias DocumentRenderer.Document

  @impl DocumentRenderer.Renderer
  def mime_type, do: "text/plain"

  @impl DocumentRenderer.Renderer
  def render(%Document{title: title, sections: sections}) do
    body =
      sections
      |> Enum.map(&render_section/1)
      |> Enum.join("\n\n")

    {:ok, "#{String.upcase(title)}\n#{String.duplicate("=", String.length(title))}\n\n#{body}"}
  end

  defp render_section(%{heading: nil, body: body}), do: body
  defp render_section(%{heading: heading, body: body}) do
    "#{heading}\n#{String.duplicate("-", String.length(heading))}\n#{body}"
  end
end

defmodule DocumentRenderer do
  @moduledoc """
  Entry point for rendering documents. Selects the appropriate renderer
  based on the document's declared format and delegates to it.
  """

  alias DocumentRenderer.{Document, HtmlRenderer, MarkdownRenderer, PlainTextRenderer}

  @renderer_map %{
    html: HtmlRenderer,
    markdown: MarkdownRenderer,
    plain_text: PlainTextRenderer
  }

  @spec render(Document.t()) :: {:ok, %{content: String.t(), mime_type: String.t()}} | {:error, term()}
  def render(%Document{format: format} = document) do
    case Map.fetch(@renderer_map, format) do
      {:ok, renderer} ->
        with {:ok, content} <- renderer.render(document) do
          {:ok, %{content: content, mime_type: renderer.mime_type()}}
        end

      :error ->
        {:error, {:unsupported_format, format}}
    end
  end
end
```
