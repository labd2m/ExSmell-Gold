```elixir
defmodule MyApp.Platform.FeatureFlaggedRouter do
  @moduledoc """
  A Phoenix router plug that conditionally enables or disables API route
  groups based on feature flag state. Routes in a flagged group return
  404 when the flag is off, making it safe to deploy code behind a flag
  and enable it without a redeploy.

  Usage in your router pipeline:

      plug MyApp.Platform.FeatureFlaggedRouter, flag: "new_payments_api"
  """

  @behaviour Plug

  import Plug.Conn

  alias MyApp.FeatureFlags

  @impl Plug
  def init(opts) do
    flag = Keyword.fetch!(opts, :flag)
    %{flag: flag, fallback_status: Keyword.get(opts, :fallback_status, 404)}
  end

  @impl Plug
  def call(conn, %{flag: flag, fallback_status: status}) do
    if FeatureFlags.enabled?(flag) do
      conn
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, encode_not_found(flag))
      |> halt()
    end
  end

  @spec encode_not_found(String.t()) :: String.t()
  defp encode_not_found(_flag) do
    Jason.encode!(%{error: %{code: "not_found", message: "This endpoint is not available"}})
  end
end

defmodule MyApp.Platform.ConditionalMiddleware do
  @moduledoc """
  Applies a list of plugs to a connection only when a predicate function
  returns `true`. Useful for applying middleware (authentication, rate
  limiting, request logging) to a subset of routes without duplicating
  pipeline definitions.

  Usage:

      plug MyApp.Platform.ConditionalMiddleware,
        when: &MyApp.Router.Helpers.api_request?/1,
        plugs: [{MyApp.Plug.RequireAuth, []}, {MyApp.RateLimiter.Plug, []}]
  """

  @behaviour Plug

  @impl Plug
  def init(opts) do
    predicate = Keyword.fetch!(opts, :when)
    plug_specs = Keyword.fetch!(opts, :plugs)

    compiled =
      Enum.map(plug_specs, fn
        {module, plug_opts} -> {module, module.init(plug_opts)}
        module when is_atom(module) -> {module, module.init([])}
      end)

    %{predicate: predicate, plugs: compiled}
  end

  @impl Plug
  def call(conn, %{predicate: predicate, plugs: plugs}) do
    if predicate.(conn) do
      Enum.reduce_while(plugs, conn, fn {module, opts}, acc ->
        updated = module.call(acc, opts)
        if updated.halted, do: {:halt, updated}, else: {:cont, updated}
      end)
    else
      conn
    end
  end
end

defmodule MyApp.Plug.RequestLogger do
  @moduledoc """
  Logs structured request metadata at the start and end of each HTTP
  request. Works alongside `MyApp.Plug.RequestTracer` to include the
  active trace ID in every log line.
  """

  @behaviour Plug

  import Plug.Conn
  require Logger

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    start_ms = System.monotonic_time(:millisecond)

    Logger.info("http_request_started",
      method: conn.method,
      path: conn.request_path,
      remote_ip: format_ip(conn.remote_ip)
    )

    register_before_send(conn, fn completed ->
      duration_ms = System.monotonic_time(:millisecond) - start_ms

      Logger.info("http_request_completed",
        method: completed.method,
        path: completed.request_path,
        status: completed.status,
        duration_ms: duration_ms
      )

      completed
    end)
  end

  @spec format_ip(:inet.ip_address() | nil) :: String.t()
  defp format_ip(nil), do: "unknown"
  defp format_ip(ip), do: ip |> Tuple.to_list() |> Enum.join(".")
end
```
