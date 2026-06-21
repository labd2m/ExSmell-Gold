# Code Smell Example 16

- **Smell name:** Agent Obsession
- **Expected smell location:** Modules `RateLimiter`, `ApiGateway`, `ThrottleReporter`, and `QuotaResetter`
- **Affected functions:** `RateLimiter.init/1`, `ApiGateway.handle_request/3`, `ThrottleReporter.over_limit_clients/1`, `QuotaResetter.reset_all/1`
- **Short explanation:** The Agent tracking per-client API usage counts is directly accessed by four different modules. No single module serves as the authoritative interface, so quota logic (incrementing, checking, resetting) is split across unrelated responsibilities, making it easy to introduce inconsistencies.

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

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because RateLimiter directly reads and writes Agent state
  # for quota tracking, while ApiGateway, ThrottleReporter, and QuotaResetter also
  # directly interact with the same Agent, distributing ownership across four modules.
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
  # VALIDATION: SMELL END
end

defmodule ApiGateway do
  @moduledoc """
  Routes incoming API requests and enforces rate limits.
  """

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because ApiGateway directly reads and updates the Agent
  # to enforce rate limits, rather than going through a dedicated RateLimiter API.
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
  # VALIDATION: SMELL END

  defp dispatch(%{path: path, method: method}) do
    IO.puts("Dispatching #{method} #{path}")
    {:ok, %{status: 200, body: "OK"}}
  end
end

defmodule ThrottleReporter do
  @moduledoc """
  Reports on clients that have exceeded or are approaching their rate limit.
  """

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because ThrottleReporter directly reads Agent state to
  # compute throttle reports, bypassing any accessor offered by RateLimiter.
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
  # VALIDATION: SMELL END
end

defmodule QuotaResetter do
  @moduledoc """
  Resets usage counts at the start of a new billing window.
  """

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because QuotaResetter directly wipes Agent state to
  # reset counters, yet another module independently mutating shared Agent data.
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
  # VALIDATION: SMELL END
end
```
