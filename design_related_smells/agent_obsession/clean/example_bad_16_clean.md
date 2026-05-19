```elixir
defmodule RateLimiter do
  @moduledoc """
  Starts the Agent that tracks per-client request counts and limits.
  """

  @default_limit 1000

  def init(limits \\ %{}) do
    {:ok, pid} =
      Agent.start_link(fn ->
        %{counts: %{}, limits: Map.merge(%{default: @default_limit}, limits)}
      end)

    pid
  end

  def increment(pid, client_id) do
    Agent.update(pid, fn state ->
      new_count = Map.get(state.counts, client_id, 0) + 1
      %{state | counts: Map.put(state.counts, client_id, new_count)}
    end)
  end

  def check(pid, client_id) do
    Agent.get(pid, fn %{counts: counts, limits: limits} ->
      count = Map.get(counts, client_id, 0)
      limit = Map.get(limits, client_id, limits[:default])
      count < limit
    end)
  end
end

defmodule ApiGateway do
  @moduledoc """
  Routes incoming API requests and enforces rate limits.
  """

  def handle_request(pid, client_id, request) do
    allowed =
      Agent.get(pid, fn %{counts: counts, limits: limits} ->
        count = Map.get(counts, client_id, 0)
        limit = Map.get(limits, client_id, limits[:default])
        count < limit
      end)

    if allowed do
      Agent.update(pid, fn state ->
        new_count = Map.get(state.counts, client_id, 0) + 1
        %{state | counts: Map.put(state.counts, client_id, new_count)}
      end)

      dispatch(request)
    else
      {:error, :rate_limit_exceeded}
    end
  end

  defp dispatch(%{path: path, method: method}) do
    IO.puts("Dispatching #{method} #{path}")
    {:ok, %{status: 200, body: "OK"}}
  end
end

defmodule ThrottleReporter do
  @moduledoc """
  Reports on clients that have exceeded or are approaching their rate limit.
  """

  def over_limit_clients(pid) do
    Agent.get(pid, fn %{counts: counts, limits: limits} ->
      default = limits[:default]

      counts
      |> Enum.filter(fn {client_id, count} ->
        limit = Map.get(limits, client_id, default)
        count >= limit
      end)
      |> Enum.map(fn {client_id, count} ->
        limit = Map.get(limits, client_id, default)
        %{client_id: client_id, count: count, limit: limit}
      end)
    end)
  end

  def approaching_limit(pid, threshold \\ 0.9) do
    Agent.get(pid, fn %{counts: counts, limits: limits} ->
      default = limits[:default]

      Enum.filter(counts, fn {client_id, count} ->
        limit = Map.get(limits, client_id, default)
        count / limit >= threshold and count < limit
      end)
    end)
  end
end

defmodule QuotaResetter do
  @moduledoc """
  Resets usage counts at the start of a new billing window.
  """

  def reset_all(pid) do
    Agent.update(pid, fn state -> %{state | counts: %{}} end)
    :ok
  end

  def reset_client(pid, client_id) do
    Agent.update(pid, fn state ->
      %{state | counts: Map.delete(state.counts, client_id)}
    end)

    :ok
  end

  def schedule_reset(pid, interval_ms) do
    spawn(fn ->
      Process.sleep(interval_ms)
      reset_all(pid)
    end)
  end
end
```
