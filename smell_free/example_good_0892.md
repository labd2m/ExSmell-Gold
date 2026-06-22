```elixir
defmodule MyAppWeb.Plug.ContentSecurityPolicy do
  @moduledoc """
  Builds and injects a `Content-Security-Policy` response header from a
  declarative directive map. Each endpoint group in the router can provide
  its own directive overrides via `init/1` options, allowing fine-grained
  policies without duplicating header assembly logic. Nonce-based script
  whitelisting is supported: a per-request nonce is generated, stored in
  `conn.assigns[:csp_nonce]`, and injected into the `script-src` directive
  so inline scripts in server-rendered views can reference it.
  """

  @behaviour Plug

  import Plug.Conn

  @default_directives %{
    "default-src" => ["'self'"],
    "script-src" => ["'self'"],
    "style-src" => ["'self'", "'unsafe-inline'"],
    "img-src" => ["'self'", "data:", "https:"],
    "font-src" => ["'self'"],
    "connect-src" => ["'self'"],
    "frame-ancestors" => ["'none'"],
    "form-action" => ["'self'"],
    "base-uri" => ["'self'"],
    "object-src" => ["'none'"]
  }

  @impl Plug
  def init(opts) do
    overrides = Keyword.get(opts, :directives, %{})
    report_only = Keyword.get(opts, :report_only, false)
    nonce = Keyword.get(opts, :nonce, false)

    merged =
      Map.merge(@default_directives, stringify_keys(overrides))

    %{directives: merged, report_only: report_only, nonce: nonce}
  end

  @impl Plug
  def call(conn, %{directives: directives, report_only: report_only, nonce: use_nonce}) do
    {conn, effective_directives} =
      if use_nonce do
        nonce = generate_nonce()
        updated_script_src = ["'nonce-#{nonce}'" | Map.get(directives, "script-src", ["'self'"])]
        updated = Map.put(directives, "script-src", updated_script_src)
        {assign(conn, :csp_nonce, nonce), updated}
      else
        {conn, directives}
      end

    header_name = if report_only, do: "content-security-policy-report-only", else: "content-security-policy"
    header_value = build_header(effective_directives)

    put_resp_header(conn, header_name, header_value)
  end

  @doc """
  Adds a source to an existing directive in the initialised options.
  Useful for composing policies across pipelines without full replacement.
  """
  @spec add_source(map(), binary(), binary()) :: map()
  def add_source(%{directives: directives} = opts, directive, source)
      when is_binary(directive) and is_binary(source) do
    updated =
      Map.update(directives, directive, [source], fn sources ->
        Enum.uniq([source | sources])
      end)

    %{opts | directives: updated}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp build_header(directives) do
    directives
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {directive, sources} ->
      "#{directive} #{Enum.join(sources, " ")}"
    end)
    |> Enum.join("; ")
  end

  defp generate_nonce do
    :crypto.strong_rand_bytes(16) |> Base.encode64(padding: false)
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end
end

defmodule MyAppWeb.Plug.SecurityHeaders do
  @moduledoc """
  Sets a collection of standard security response headers that apply to
  every response regardless of content type or route. Combines with
  `ContentSecurityPolicy` to form a complete defensive header set.
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    conn
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("x-frame-options", "DENY")
    |> put_resp_header("x-xss-protection", "1; mode=block")
    |> put_resp_header("referrer-policy", "strict-origin-when-cross-origin")
    |> put_resp_header("permissions-policy", "camera=(), microphone=(), geolocation=()")
    |> put_resp_header(
      "strict-transport-security",
      "max-age=63072000; includeSubDomains; preload"
    )
  end
end
```
