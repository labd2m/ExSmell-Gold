```elixir
defmodule AppWeb.Plugs.HealthCheck do
  @moduledoc """
  A Plug that exposes a `/health` endpoint with structured status for all
  registered service dependencies.

  Deep health checks (database, cache, external APIs) are registered as
  named functions and executed in parallel. The overall status is `:healthy`
  only when all checks pass; otherwise it is `:degraded` or `:unhealthy`.
  """

  import Plug.Conn

  alias Platform.HealthAggregator

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%{request_path: "/health"} = conn, opts) do
    mode = Keyword.get(opts, :mode, :deep)
    respond(conn, mode)
  end

  def call(conn, _opts), do: conn

  defp respond(conn, :shallow) do
    send_json(conn, 200, %{status: :healthy, mode: :shallow, checked_at: utc_now()})
  end

  defp respond(conn, :deep) do
    report = HealthAggregator.run_all()
    status_code = if report.status == :healthy, do: 200, else: 503
    send_json(conn, status_code, report)
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end

  defp utc_now, do: DateTime.to_iso8601(DateTime.utc_now())
end

defmodule Platform.HealthAggregator do
  @moduledoc """
  Runs registered health checks concurrently and aggregates their results
  into a single structured report.
  """

  @type check_name :: atom()
  @type check_fn :: (-> :ok | {:error, term()})
  @type check_result :: %{name: check_name(), status: :healthy | :unhealthy, detail: term()}
  @type report :: %{status: :healthy | :degraded | :unhealthy, checks: [check_result()], checked_at: String.t()}

  @check_timeout_ms 5_000

  @doc "Registers a named health check function globally."
  @spec register(check_name(), check_fn()) :: :ok
  def register(name, fun) when is_atom(name) and is_function(fun, 0) do
    Application.put_env(:platform, {:health_check, name}, fun)
  end

  @doc "Runs all registered checks in parallel and returns a combined report."
  @spec run_all() :: report()
  def run_all do
    checks = load_checks()

    results =
      checks
      |> Task.async_stream(&run_check/1, timeout: @check_timeout_ms, on_timeout: :kill_task)
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, _} -> %{name: :unknown, status: :unhealthy, detail: :timeout}
      end)

    overall = derive_overall_status(results)

    %{
      status: overall,
      checks: results,
      checked_at: DateTime.to_iso8601(DateTime.utc_now())
    }
  end

  defp load_checks do
    Application.get_all_env(:platform)
    |> Enum.flat_map(fn
      {{:health_check, name}, fun} -> [{name, fun}]
      _ -> []
    end)
  end

  defp run_check({name, fun}) do
    case fun.() do
      :ok -> %{name: name, status: :healthy, detail: nil}
      {:error, reason} -> %{name: name, status: :unhealthy, detail: inspect(reason)}
    end
  rescue
    error -> %{name: name, status: :unhealthy, detail: inspect(error)}
  end

  defp derive_overall_status(results) do
    unhealthy_count = Enum.count(results, &(&1.status == :unhealthy))
    total = length(results)

    cond do
      unhealthy_count == 0 -> :healthy
      unhealthy_count < total -> :degraded
      true -> :unhealthy
    end
  end
end
```
