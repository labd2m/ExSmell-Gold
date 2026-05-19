```elixir
defmodule MyApp.CircuitBreakerTask do
  @moduledoc """
  Circuit breaker for external service calls.
  Transitions between closed, open, and half-open states to prevent
  cascading failures when a downstream service is degraded.
  """

  alias MyApp.{AlertService, MetricsCollector}

  @failure_threshold 5
  @success_threshold 2
  @open_timeout_ms 30_000
  @half_open_probe_limit 3

  def start_breaker(service_name, config \\ %{}) do
    Task.start_link(fn ->
      state = %{
        service_name: service_name,
        config: Map.merge(default_config(), config),
        status: :closed,
        failure_count: 0,
        success_count: 0,
        probe_count: 0,
        last_opened_at: nil,
        last_failure_at: nil,
        total_requests: 0,
        total_failures: 0
      }

      breaker_loop(state)
    end)
  end

  defp default_config do
    %{
      failure_threshold: @failure_threshold,
      success_threshold: @success_threshold,
      open_timeout_ms: @open_timeout_ms,
      probe_limit: @half_open_probe_limit
    }
  end

  defp breaker_loop(state) do
    receive do
      {:allow?, from} ->
        {allowed, new_state} = evaluate_allow(state)
        send(from, {:ok, allowed})
        breaker_loop(new_state)

      {:record_success, from} ->
        new_state =
          case state.status do
            :half_open ->
              new_successes = state.success_count + 1

              if new_successes >= state.config.success_threshold do
                MetricsCollector.increment(:circuit_breaker_closed, service: state.service_name)
                AlertService.notify(:circuit_breaker_closed, %{service: state.service_name})

                %{
                  state
                  | status: :closed,
                    failure_count: 0,
                    success_count: 0,
                    probe_count: 0
                }
              else
                %{state | success_count: new_successes}
              end

            _ ->
              %{state | failure_count: 0}
          end

        send(from, :ok)
        breaker_loop(%{new_state | total_requests: new_state.total_requests + 1})

      {:record_failure, from} ->
        now = DateTime.utc_now()

        new_state =
          case state.status do
            :closed ->
              new_failures = state.failure_count + 1

              if new_failures >= state.config.failure_threshold do
                AlertService.notify(:circuit_breaker_opened, %{
                  service: state.service_name,
                  failures: new_failures
                })

                MetricsCollector.increment(:circuit_breaker_opened, service: state.service_name)

                Process.send_after(
                  self(),
                  :try_half_open,
                  state.config.open_timeout_ms
                )

                %{
                  state
                  | status: :open,
                    failure_count: new_failures,
                    last_opened_at: now,
                    last_failure_at: now
                }
              else
                %{state | failure_count: new_failures, last_failure_at: now}
              end

            :half_open ->
              MetricsCollector.increment(:circuit_breaker_reopened, service: state.service_name)

              Process.send_after(self(), :try_half_open, state.config.open_timeout_ms)

              %{
                state
                | status: :open,
                  failure_count: 1,
                  success_count: 0,
                  probe_count: 0,
                  last_opened_at: now,
                  last_failure_at: now
              }

            :open ->
              %{state | last_failure_at: now}
          end

        send(from, :ok)
        breaker_loop(%{new_state | total_failures: new_state.total_failures + 1})

      :try_half_open ->
        if state.status == :open do
          MetricsCollector.increment(:circuit_breaker_half_open, service: state.service_name)
          breaker_loop(%{state | status: :half_open, probe_count: 0, success_count: 0})
        else
          breaker_loop(state)
        end

      {:get_state, from} ->
        info = Map.take(state, [:status, :failure_count, :success_count, :total_requests, :total_failures, :last_opened_at])
        send(from, {:ok, info})
        breaker_loop(state)

      :stop ->
        :ok
    end
  end

  defp evaluate_allow(%{status: :closed} = state) do
    {true, state}
  end

  defp evaluate_allow(%{status: :open} = state) do
    {false, state}
  end

  defp evaluate_allow(%{status: :half_open} = state) do
    if state.probe_count < state.config.probe_limit do
      {true, %{state | probe_count: state.probe_count + 1}}
    else
      {false, state}
    end
  end

  def allow?(pid) do
    send(pid, {:allow?, self()})

    receive do
      {:ok, allowed} -> {:ok, allowed}
    after
      1_000 -> {:error, :timeout}
    end
  end

  def record_success(pid) do
    send(pid, {:record_success, self()})

    receive do
      :ok -> :ok
    after
      1_000 -> {:error, :timeout}
    end
  end

  def record_failure(pid) do
    send(pid, {:record_failure, self()})

    receive do
      :ok -> :ok
    after
      1_000 -> {:error, :timeout}
    end
  end

  def get_state(pid) do
    send(pid, {:get_state, self()})

    receive do
      {:ok, info} -> {:ok, info}
    after
      1_000 -> {:error, :timeout}
    end
  end
end
```
