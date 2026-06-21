```elixir
defmodule Infra.HealthProbe do
  @moduledoc """
  Behaviour and default implementations for application health probes.
  Each probe module checks one external dependency and returns a
  structured status. This module also provides a `run_all/1` helper
  that executes a list of probes concurrently and aggregates results
  within a bounded timeout.
  """

  @type status :: :ok | :degraded | :down
  @type probe_result :: {:ok, String.t()} | {:degraded, String.t()} | {:error, String.t()}

  @callback check() :: probe_result()

  @doc """
  Runs all probes in `modules` concurrently and returns a map of
  module name to status. Probes that exceed `timeout_ms` are reported
  as `:down`.
  """
  @spec run_all([module()], pos_integer()) :: %{module() => %{status: status(), detail: String.t()}}
  def run_all(modules, timeout_ms \ 5_000) when is_list(modules) and is_integer(timeout_ms) do
    tasks =
      Enum.map(modules, fn mod ->
        {mod, Task.async(fn -> safe_check(mod) end)}
      end)

    Map.new(tasks, fn {mod, task} ->
      result =
        case Task.yield(task, timeout_ms) || Task.shutdown(task) do
          {:ok, probe_result} -> interpret(probe_result)
          nil -> %{status: :down, detail: "probe timed out after #{timeout_ms}ms"}
          {:exit, reason} -> %{status: :down, detail: "probe crashed: #{inspect(reason)}"}
        end

      {mod, result}
    end)
  end

  defp safe_check(mod) do
    mod.check()
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp interpret({:ok, detail}), do: %{status: :ok, detail: detail}
  defp interpret({:degraded, detail}), do: %{status: :degraded, detail: detail}
  defp interpret({:error, detail}), do: %{status: :down, detail: detail}
end

defmodule Infra.DatabaseProbe do
  @moduledoc "Health probe that verifies the primary database is reachable."

  @behaviour Infra.HealthProbe

  @impl Infra.HealthProbe
  def check do
    case MyApp.Repo.query("SELECT 1", [], timeout: 3_000) do
      {:ok, _} -> {:ok, "database reachable"}
      {:error, reason} -> {:error, "database unreachable: #{inspect(reason)}"}
    end
  rescue
    e -> {:error, "database probe raised: #{Exception.message(e)}"}
  end
end

defmodule Infra.RedisProbe do
  @moduledoc "Health probe that verifies the Redis cache is reachable."

  @behaviour Infra.HealthProbe

  @impl Infra.HealthProbe
  def check do
    case Redix.command(:redix, ["PING"]) do
      {:ok, "PONG"} -> {:ok, "redis reachable"}
      {:ok, other} -> {:degraded, "redis responded with: #{other}"}
      {:error, reason} -> {:error, "redis unreachable: #{inspect(reason)}"}
    end
  rescue
    e -> {:error, "redis probe raised: #{Exception.message(e)}"}
  end
end
```
