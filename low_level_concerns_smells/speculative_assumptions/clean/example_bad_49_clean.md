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
