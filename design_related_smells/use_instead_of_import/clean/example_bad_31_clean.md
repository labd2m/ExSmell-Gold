```elixir
defmodule HtmlBuilder do
  def tag(name, attrs, content) do
    attr_str =
      attrs
      |> Enum.map(fn {k, v} -> "#{k}=\"#{v}\"" end)
      |> Enum.join(" ")

    opening = if attr_str == "", do: "<#{name}>", else: "<#{name} #{attr_str}>"
    "#{opening}#{content}</#{name}>"
  end

  def table(rows, headers) do
    header_row =
      headers
      |> Enum.map(&tag("th", [style: "padding:8px;text-align:left;"], &1))
      |> Enum.join()
      |> then(&tag("tr", [], &1))

    body_rows =
      Enum.map(rows, fn row ->
        cells = Enum.map(row, &tag("td", [style: "padding:8px;"], to_string(&1)))
        tag("tr", [], Enum.join(cells))
      end)

    tag("table", [border: "0", cellpadding: "0", cellspacing: "0", width: "100%"],
        header_row <> Enum.join(body_rows))
  end

  def css_inline(html, css_map) do
    Enum.reduce(css_map, html, fn {selector, props}, acc ->
      String.replace(acc, ~r/class="#{selector}"/, "style=\"#{props}\"")
    end)
  end
end

defmodule MarkupHelpers do
  defmacro __using__(_opts) do
    quote do
      import HtmlBuilder

      def wrap_layout(content, opts \\ []) do
        bg      = Keyword.get(opts, :bg, "#ffffff")
        padding = Keyword.get(opts, :padding, "20px")

        """
        <html><body style="background:#{bg};font-family:sans-serif;">
          <table width="600" align="center" style="padding:#{padding};">
            <tr><td>#{content}</td></tr>
          </table>
        </body></html>
        """
      end

      def button(text, url) do
        tag("a",
          [href: url, style: "background:#3b82f6;color:#fff;padding:10px 20px;text-decoration:none;border-radius:4px;"],
          text)
      end

      def section(title, body) do
        heading = tag("h2", [style: "margin-top:0;"], title)
        heading <> tag("p", [style: "line-height:1.6;"], body)
      end
    end
  end
end

defmodule EmailComposer do
  use MarkupHelpers

  @inline_styles %{
    "highlight"  => "background:#fef3c7;padding:4px 8px;border-radius:2px;",
    "muted"      => "color:#6b7280;font-size:12px;",
    "header-row" => "background:#f3f4f6;"
  }

  def compose(:welcome, assigns) do
    body = section("Welcome, #{assigns.name}!",
             "Your account at #{assigns.app_name} has been created successfully.")

    cta = button("Get Started", assigns.dashboard_url)

    html = wrap_layout(body <> cta, bg: "#f9fafb")
    final = css_inline(html, @inline_styles)

    %{
      to:      assigns.email,
      subject: "Welcome to #{assigns.app_name}",
      html:    final,
      text:    "Welcome #{assigns.name}! Visit #{assigns.dashboard_url} to get started."
    }
  end

  def compose(:invoice, assigns) do
    rows =
      Enum.map(assigns.line_items, fn item ->
        [item.description, item.qty, "$#{item.unit_price}", "$#{item.total}"]
      end)

    invoice_table = table(rows, ["Description", "Qty", "Unit Price", "Total"])
    total_row     = tag("p", [style: "text-align:right;font-weight:bold;"], "Total: $#{assigns.total}")

    html = wrap_layout(
      section("Invoice ##{assigns.invoice_id}", "Thank you for your business.") <>
      invoice_table <>
      total_row
    )

    final = css_inline(html, @inline_styles)

    %{
      to:      assigns.email,
      subject: "Invoice ##{assigns.invoice_id}",
      html:    final,
      text:    "Invoice #{assigns.invoice_id}: $#{assigns.total}"
    }
  end

  def compose_digest(user, activity_items) do
    rows = Enum.map(activity_items, fn a -> [a.event, a.description, a.occurred_at] end)
    digest_table = table(rows, ["Event", "Description", "Date"])
    cta          = button("View All Activity", "https://app.example.com/activity")

    html = wrap_layout(
      section("Your Weekly Digest", "Here's what happened on your account this week.") <>
      digest_table <>
      cta
    )

    %{
      to:      user.email,
      subject: "Your weekly digest",
      html:    css_inline(html, @inline_styles),
      text:    "You had #{length(activity_items)} events this week."
    }
  end

  def preview(email) do
    Map.put(email, :preview_text, String.slice(email.text, 0, 140))
  end
end
```
