# Annotated Bad Example 18

**Smell:** "Use" instead of "import"
**Expected Smell Location:** `Notifications.EmailComposer`, `use Notifications.RenderHelpers` directive
**Affected Functions:** `compose/2`, `compose_bulk/2`, `render_preview/1`
**Explanation:** `Notifications.EmailComposer` calls `use Notifications.RenderHelpers` to gain access to text-interpolation and HTML-escaping helpers. The `__using__/1` macro in `RenderHelpers` also secretly injects an alias for `Notifications.LayoutStore` and sets `@default_sender` and `@max_subject_length` attributes. The client never explicitly requested those; any reader of `EmailComposer` who does not trace through the macro will be confused about where `LayoutStore` and the module attributes originate. Using `import Notifications.RenderHelpers` instead would be transparent and sufficient.

```elixir
defmodule Notifications.RenderHelpers do
  @moduledoc """
  Stateless helpers for interpolating template variables and
  sanitising HTML content in notification messages.
  """

  def interpolate(template, vars) when is_binary(template) and is_map(vars) do
    Enum.reduce(vars, template, fn {key, value}, acc ->
      String.replace(acc, "{{#{key}}}", to_string(value))
    end)
  end

  def escape_html(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  def strip_html(html) do
    Regex.replace(~r/<[^>]+>/, html, "")
  end

  def truncate(text, max_length) when is_binary(text) and is_integer(max_length) do
    if String.length(text) > max_length do
      String.slice(text, 0, max_length - 3) <> "..."
    else
      text
    end
  end

  def plain_text_from_html(html) do
    html
    |> strip_html()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  # VALIDATION: SMELL START - "Use" instead of "import"
  # VALIDATION: This is a smell because __using__/1 propagates an alias to
  # Notifications.LayoutStore and two module attributes into any client that
  # calls `use Notifications.RenderHelpers`. The client receives these hidden
  # injections without asking for them, making dependencies non-obvious.
  defmacro __using__(_opts) do
    quote do
      import Notifications.RenderHelpers
      alias Notifications.LayoutStore

      @default_sender    "noreply@example.com"
      @max_subject_length 78
    end
  end
  # VALIDATION: SMELL END - "Use" instead of "import"
end

defmodule Notifications.LayoutStore do
  @moduledoc "Retrieves HTML layout wrappers for notification emails."

  def fetch(:transactional) do
    {:ok,
     """
     <html><body>
     <div class="header">MyApp</div>
     <div class="content">{{body}}</div>
     <div class="footer">© MyApp Inc.</div>
     </body></html>
     """}
  end

  def fetch(:marketing) do
    {:ok,
     """
     <html><body style="background:#f4f4f4">
     <div class="wrapper">{{body}}</div>
     </body></html>
     """}
  end

  def fetch(_), do: {:error, :unknown_layout}
end

defmodule Notifications.EmailComposer do
  # VALIDATION: SMELL START - "Use" instead of "import"
  # VALIDATION: This is a smell because `use Notifications.RenderHelpers` silently
  # injects alias Notifications.LayoutStore and module attributes @default_sender
  # and @max_subject_length. A reader of EmailComposer cannot determine where
  # LayoutStore, @default_sender, or @max_subject_length come from without
  # inspecting the RenderHelpers macro. `import Notifications.RenderHelpers`
  # would supply only the needed functions explicitly.
  use Notifications.RenderHelpers
  # VALIDATION: SMELL END - "Use" instead of "import"

  @moduledoc """
  Composes structured email messages from templates and variable maps,
  applying HTML layout wrappers and plain-text fallback generation.
  """

  defstruct [:to, :from, :subject, :html_body, :text_body, :layout, :metadata]

  def compose(template, vars) when is_map(vars) do
    subject   = vars |> Map.get(:subject, "Notification") |> truncate(@max_subject_length)
    html_body = interpolate(template[:html] || "", vars)
    text_body = plain_text_from_html(html_body)

    with {:ok, layout} <- LayoutStore.fetch(template[:layout] || :transactional) do
      wrapped = interpolate(layout, %{body: html_body})

      {:ok, %__MODULE__{
        to:        vars[:to],
        from:      vars[:from] || @default_sender,
        subject:   subject,
        html_body: wrapped,
        text_body: text_body,
        layout:    template[:layout] || :transactional,
        metadata:  %{composed_at: DateTime.utc_now()}
      }}
    end
  end

  def compose_bulk(template, recipients) when is_list(recipients) do
    recipients
    |> Enum.map(fn recipient ->
      case compose(template, recipient) do
        {:ok, email} -> {:ok, email}
        {:error, _}  = err -> err
      end
    end)
    |> Enum.split_with(fn
      {:ok, _} -> true
      _        -> false
    end)
    |> then(fn {ok, errs} ->
      %{
        composed:  Enum.map(ok, fn {:ok, e} -> e end),
        failed:    Enum.map(errs, fn {:error, r} -> r end),
        total:     length(recipients)
      }
    end)
  end

  def render_preview(%__MODULE__{} = email) do
    """
    From    : #{email.from}
    To      : #{email.to}
    Subject : #{email.subject}
    Layout  : #{email.layout}
    ---
    #{email.text_body}
    """
  end

  def valid?(%__MODULE__{to: to, subject: subj}) do
    is_binary(to) and String.contains?(to, "@") and
      is_binary(subj) and String.length(subj) > 0
  end
end
```
