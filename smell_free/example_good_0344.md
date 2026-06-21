```elixir
defmodule AppWeb.Plugs.ContentSecurityPolicy do
  @moduledoc """
  A Plug that builds and injects a `Content-Security-Policy` header.

  Directives are composed programmatically from options, making CSP policies
  auditable, testable, and environment-aware. Nonces for inline scripts are
  generated per-request and stored in `conn.assigns.csp_nonce`.
  """

  import Plug.Conn

  @behaviour Plug

  @type source :: String.t()
  @type directive :: {atom(), [source()]}
  @type opt ::
          {:directives, [directive()]}
          | {:nonce_for, [atom()]}
          | {:report_uri, String.t()}
          | {:report_only, boolean()}

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    nonce = generate_nonce()
    directives = Keyword.get(opts, :directives, default_directives())
    nonce_targets = Keyword.get(opts, :nonce_for, [:script_src])
    report_uri = Keyword.get(opts, :report_uri)
    report_only = Keyword.get(opts, :report_only, false)

    policy =
      directives
      |> inject_nonces(nonce, nonce_targets)
      |> maybe_add_report_uri(report_uri)
      |> build_header_value()

    header_name = if report_only, do: "content-security-policy-report-only", else: "content-security-policy"

    conn
    |> assign(:csp_nonce, nonce)
    |> put_resp_header(header_name, policy)
  end

  defp default_directives do
    [
      {:default_src, ["'self'"]},
      {:script_src, ["'self'"]},
      {:style_src, ["'self'", "'unsafe-inline'"]},
      {:img_src, ["'self'", "data:", "https:"]},
      {:font_src, ["'self'"]},
      {:connect_src, ["'self'"]},
      {:frame_ancestors, ["'none'"]},
      {:base_uri, ["'self'"]},
      {:form_action, ["'self'"]}
    ]
  end

  defp inject_nonces(directives, nonce, nonce_targets) do
    Enum.map(directives, fn {directive_name, sources} ->
      if directive_name in nonce_targets do
        {directive_name, sources ++ ["'nonce-#{nonce}'"]}
      else
        {directive_name, sources}
      end
    end)
  end

  defp maybe_add_report_uri(directives, nil), do: directives

  defp maybe_add_report_uri(directives, report_uri) do
    directives ++ [{:report_uri, [report_uri]}]
  end

  defp build_header_value(directives) do
    directives
    |> Enum.map_join("; ", fn {name, sources} ->
      directive_key = name |> Atom.to_string() |> String.replace("_", "-")
      "#{directive_key} #{Enum.join(sources, " ")}"
    end)
  end

  defp generate_nonce do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.encode64(padding: false)
  end
end
```
