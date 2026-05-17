# Annotated Example — Speculative Assumptions

## Metadata

- **Smell name:** Speculative Assumptions
- **Expected smell location:** `Monitoring.HealthAggregator.overall_status/1`, around the `Enum.reduce` with a default that masks failures
- **Affected function(s):** `overall_status/1`
- **Short explanation:** The function reduces a list of health check results to determine the overall system health. It uses `Map.get(result, :status, :healthy)` to extract each check's status, so if a check result is missing the `:status` key entirely (e.g., because a checker returned a raw error tuple or an unexpected map shape), the default `:healthy` is silently used. A failing subsystem is thus counted as healthy, and `overall_status/1` may return `:healthy` even when a critical component is down.

---

```elixir
defmodule Monitoring.HealthAggregator do
  @moduledoc """
  Aggregates health check results from all registered subsystem health checkers
  and computes an overall system health status for the /health endpoint and
  alerting integrations.

  Each checker module must implement `check/0` returning:
    %{status: :healthy | :degraded | :unhealthy, details: map(), latency_ms: integer()}
  """

  require Logger

  @checkers [
    Monitoring.Checkers.Database,
    Monitoring.Checkers.Redis,
    Monitoring.Checkers.MessageQueue,
    Monitoring.Checkers.ExternalPaymentGateway,
    Monitoring.Checkers.EmailRelay,
    Monitoring.Checkers.StorageService,
    Monitoring.Checkers.SearchIndex
  ]

  @timeout_ms 5_000

  def run do
    results = gather_results()

    %{
      status:     overall_status(results),
      checks:     results,
      checked_at: DateTime.utc_now(),
      version:    Application.get_env(:app, :version, "unknown")
    }
  end

  defp gather_results do
    @checkers
    |> Task.async_stream(
      fn checker ->
        name = checker |> Module.split() |> List.last() |> Macro.underscore()

        result =
          try do
            checker.check()
          rescue
            e ->
              Logger.error("Health checker #{name} raised: #{inspect(e)}")
              %{status: :unhealthy, details: %{error: inspect(e)}, latency_ms: nil}
          catch
            :exit, reason ->
              %{status: :unhealthy, details: %{exit: inspect(reason)}, latency_ms: nil}
          end

        {name, result}
      end,
      timeout: @timeout_ms,
      on_timeout: :kill_task
    )
    |> Enum.map(fn
      {:ok, {name, result}} ->
        {name, result}

      {:exit, :timeout} ->
        {"unknown", %{status: :unhealthy, details: %{error: "timeout"}, latency_ms: nil}}
    end)
    |> Map.new()
  end

  # VALIDATION: SMELL START - Speculative Assumptions
  # VALIDATION: This is a smell because the function uses Map.get(result, :status, :healthy)
  # VALIDATION: to extract each check's status with :healthy as the default. If a checker
  # VALIDATION: returns an unexpected shape — for example a raw {:error, reason} tuple
  # VALIDATION: stored as the map value, or a map without a :status key — Map.get silently
  # VALIDATION: returns :healthy. The faulty checker is then counted as healthy in the
  # VALIDATION: overall aggregation. The function may return :healthy when one or more
  # VALIDATION: critical systems are actually failing, giving a false green status to
  # VALIDATION: monitoring dashboards and suppressing alerts that should fire.
  defp overall_status(results) do
    statuses =
      results
      |> Map.values()
      |> Enum.map(fn result -> Map.get(result, :status, :healthy) end)

    cond do
      :unhealthy in statuses -> :unhealthy
      :degraded  in statuses -> :degraded
      true                   -> :healthy
    end
  end
  # VALIDATION: SMELL END

  def unhealthy_checks(results) do
    results
    |> Enum.filter(fn {_name, result} ->
      Map.get(result, :status) == :unhealthy
    end)
    |> Map.new()
  end

  def degraded_checks(results) do
    results
    |> Enum.filter(fn {_name, result} ->
      Map.get(result, :status) == :degraded
    end)
    |> Map.new()
  end

  def latency_summary(results) do
    results
    |> Enum.map(fn {name, result} ->
      {name, Map.get(result, :latency_ms)}
    end)
    |> Enum.reject(fn {_, lat} -> is_nil(lat) end)
    |> Enum.sort_by(&elem(&1, 1), :desc)
  end

  def format_summary(%{status: status, checks: checks, checked_at: ts}) do
    count    = map_size(checks)
    failures = checks |> Map.values() |> Enum.count(&(Map.get(&1, :status) != :healthy))

    "#{status} — #{count} checks, #{failures} failures at #{DateTime.to_string(ts)}"
  end

  def to_http_status(:healthy),   do: 200
  def to_http_status(:degraded),  do: 200
  def to_http_status(:unhealthy), do: 503
  def to_http_status(_),          do: 500
end
```
