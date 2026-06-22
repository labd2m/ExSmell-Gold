```elixir
defmodule Ops.ChaosMiddleware do
  @moduledoc """
  A Plug middleware that injects configurable fault scenarios into HTTP
  requests for chaos-engineering and resilience testing. Fault injection
  is controlled by a header flag and is only active when the application
  is running in a designated test environment. Production builds receive
  a no-op implementation that cannot be activated regardless of headers.
  """

  @behaviour Plug

  import Plug.Conn

  @fault_header "x-chaos-fault"
  @allowed_envs ~w(chaos test)

  @impl Plug
  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @impl Plug
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(%Plug.Conn{} = conn, opts) do
    env = Keyword.get(opts, :env, Application.get_env(:my_app, :env, :prod))

    if Atom.to_string(env) in @allowed_envs do
      apply_fault(conn, opts)
    else
      conn
    end
  end

  defp apply_fault(conn, opts) do
    case get_req_header(conn, @fault_header) do
      ["latency:" <> ms_str] ->
        inject_latency(conn, ms_str)

      ["error:" <> code_str] ->
        inject_error(conn, code_str, opts)

      ["random_error"] ->
        maybe_inject_random_error(conn, opts)

      _ ->
        conn
    end
  end

  defp inject_latency(conn, ms_str) do
    case Integer.parse(ms_str) do
      {ms, ""} when ms > 0 and ms <= 30_000 ->
        Process.sleep(ms)
        conn

      _ ->
        conn
    end
  end

  defp inject_error(conn, code_str, opts) do
    case Integer.parse(code_str) do
      {code, ""} when code in 400..599 ->
        body = Keyword.get(opts, :error_body, ~s({"error":"chaos_injected"}))

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(code, body)
        |> halt()

      _ ->
        conn
    end
  end

  defp maybe_inject_random_error(conn, opts) do
    error_rate = Keyword.get(opts, :error_rate, 0.1)

    if :rand.uniform() < error_rate do
      inject_error(conn, "503", opts)
    else
      conn
    end
  end
end
```
