**File:** `example_good_1408.md`

```elixir
defmodule HealthCheck.Status do
  @moduledoc "Represents the health status of a single dependency check."

  @enforce_keys [:name, :status, :checked_at]
  defstruct [:name, :status, :checked_at, :latency_ms, :detail]

  @type health :: :healthy | :degraded | :unhealthy
  @type t :: %__MODULE__{
          name: String.t(),
          status: health(),
          checked_at: DateTime.t(),
          latency_ms: non_neg_integer() | nil,
          detail: String.t() | nil
        }

  @spec healthy(String.t(), keyword()) :: t()
  def healthy(name, opts \\ []) do
    %__MODULE__{
      name: name,
      status: :healthy,
      checked_at: DateTime.utc_now(),
      latency_ms: Keyword.get(opts, :latency_ms),
      detail: Keyword.get(opts, :detail)
    }
  end

  @spec degraded(String.t(), String.t(), keyword()) :: t()
  def degraded(name, detail, opts \\ []) do
    %__MODULE__{
      name: name,
      status: :degraded,
      checked_at: DateTime.utc_now(),
      latency_ms: Keyword.get(opts, :latency_ms),
      detail: detail
    }
  end

  @spec unhealthy(String.t(), String.t(), keyword()) :: t()
  def unhealthy(name, detail, opts \\ []) do
    %__MODULE__{
      name: name,
      status: :unhealthy,
      checked_at: DateTime.utc_now(),
      latency_ms: Keyword.get(opts, :latency_ms),
      detail: detail
    }
  end
end

defmodule HealthCheck.Checker do
  @moduledoc "Behaviour for individual dependency health checkers."

  alias HealthCheck.Status

  @doc "Performs the health check and returns a Status struct."
  @callback check() :: Status.t()

  @doc "Returns the human-readable name for this check."
  @callback check_name() :: String.t()
end

defmodule HealthCheck.Aggregator do
  @moduledoc """
  Runs all registered health checks concurrently with a timeout and
  aggregates results into a single system health report.
  """

  alias HealthCheck.Status

  @default_timeout_ms 5_000

  @type report :: %{
          status: Status.health(),
          checks: [Status.t()],
          checked_at: DateTime.t()
        }

  @spec run([module()], keyword()) :: report()
  def run(checkers, opts \\ []) when is_list(checkers) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    results = run_concurrently(checkers, timeout_ms)
    aggregate(results)
  end

  defp run_concurrently(checkers, timeout_ms) do
    checkers
    |> Enum.map(fn checker ->
      Task.async(fn -> timed_check(checker) end)
    end)
    |> Enum.map(fn task ->
      case Task.yield(task, timeout_ms) || Task.shutdown(task) do
        {:ok, status} -> status
        nil -> Status.unhealthy("unknown", "health check timed out")
        {:exit, reason} -> Status.unhealthy("unknown", "check crashed: #{inspect(reason)}")
      end
    end)
  end

  defp timed_check(checker) do
    started_at = System.monotonic_time(:millisecond)
    status = checker.check()
    elapsed = System.monotonic_time(:millisecond) - started_at
    %{status | latency_ms: elapsed}
  rescue
    exception ->
      Status.unhealthy(checker.check_name(), Exception.message(exception))
  end

  defp aggregate(results) do
    overall =
      cond do
        Enum.any?(results, &(&1.status == :unhealthy)) -> :unhealthy
        Enum.any?(results, &(&1.status == :degraded)) -> :degraded
        true -> :healthy
      end

    %{status: overall, checks: results, checked_at: DateTime.utc_now()}
  end
end

defmodule HealthCheck.Checks.Database do
  @moduledoc "Health check for the primary Ecto Repo connection."

  @behaviour HealthCheck.Checker

  alias HealthCheck.Status

  @impl HealthCheck.Checker
  def check_name, do: "database"

  @impl HealthCheck.Checker
  def check do
    case MyApp.Repo.query("SELECT 1") do
      {:ok, _} -> Status.healthy("database")
      {:error, reason} -> Status.unhealthy("database", inspect(reason))
    end
  rescue
    exception -> Status.unhealthy("database", Exception.message(exception))
  end
end

defmodule HealthCheck.Plug do
  @moduledoc "A Plug that exposes a /health endpoint returning the system health report."

  import Plug.Conn

  alias HealthCheck.Aggregator

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(%Plug.Conn{request_path: "/health"} = conn, opts) do
    checkers = Keyword.get(opts, :checkers, [])
    report = Aggregator.run(checkers, Keyword.take(opts, [:timeout_ms]))
    status_code = if report.status == :unhealthy, do: 503, else: 200

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status_code, Jason.encode!(format_report(report)))
    |> halt()
  end

  def call(conn, _opts), do: conn

  defp format_report(%{status: status, checks: checks, checked_at: at}) do
    %{
      status: status,
      checked_at: DateTime.to_iso8601(at),
      checks: Enum.map(checks, fn c ->
        %{name: c.name, status: c.status, latency_ms: c.latency_ms, detail: c.detail}
      end)
    }
  end
end
```
