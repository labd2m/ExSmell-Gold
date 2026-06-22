```elixir
defmodule Ops.ConfigDriftDetector do
  @moduledoc """
  Detects configuration drift between running application state and the
  declared configuration file. On each check the detector compares live
  application environment values against the expected snapshot loaded at
  startup. Drifted keys are reported with both the expected and actual
  values so operators can identify unauthorised runtime changes.
  """

  use GenServer

  require Logger

  @type key_path :: [atom()]
  @type drift_entry :: %{
          path: key_path(),
          expected: term(),
          actual: term()
        }
  @type check_result :: %{drifted: [drift_entry()], checked_at: DateTime.t()}

  @default_check_interval_ms :timer.minutes(5)
  @drift_event [:ops, :config, :drift_detected]

  @doc "Starts the config drift detector."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the most recent drift check result."
  @spec last_result() :: check_result() | nil
  def last_result, do: GenServer.call(__MODULE__, :last_result)

  @doc "Forces an immediate drift check outside the schedule."
  @spec check_now() :: check_result()
  def check_now, do: GenServer.call(__MODULE__, :check_now)

  @doc "Returns true when the last check found no drifted keys."
  @spec clean?() :: boolean()
  def clean? do
    case last_result() do
      nil -> true
      %{drifted: []} -> true
      _ -> false
    end
  end

  @impl GenServer
  def init(opts) do
    snapshot = Keyword.get(opts, :snapshot, capture_snapshot())
    interval = Keyword.get(opts, :interval_ms, @default_check_interval_ms)
    monitored = Keyword.get(opts, :monitored_keys, default_monitored_keys())
    Process.send_after(self(), :check, interval)

    {:ok, %{snapshot: snapshot, monitored: monitored, interval: interval, last_result: nil}}
  end

  @impl GenServer
  def handle_call(:last_result, _from, state) do
    {:reply, state.last_result, state}
  end

  def handle_call(:check_now, _from, state) do
    result = run_check(state)
    {:reply, result, %{state | last_result: result}}
  end

  @impl GenServer
  def handle_info(:check, %{interval: interval} = state) do
    result = run_check(state)
    Process.send_after(self(), :check, interval)
    {:noreply, %{state | last_result: result}}
  end

  defp run_check(%{snapshot: snapshot, monitored: monitored}) do
    drifted =
      monitored
      |> Enum.flat_map(fn {app, keys} ->
        Enum.flat_map(keys, fn key_path ->
          expected = get_in(snapshot, [app | key_path])
          actual = get_live(app, key_path)

          if expected != actual do
            [%{path: [app | key_path], expected: expected, actual: actual}]
          else
            []
          end
        end)
      end)

    if not Enum.empty?(drifted) do
      Logger.warning("[ConfigDriftDetector] #{length(drifted)} key(s) have drifted")
      :telemetry.execute(@drift_event, %{count: length(drifted)}, %{keys: drifted})
    end

    %{drifted: drifted, checked_at: DateTime.utc_now()}
  end

  defp get_live(app, [key]), do: Application.get_env(app, key)
  defp get_live(app, [key | rest]) do
    case Application.get_env(app, key) do
      nil -> nil
      nested when is_map(nested) -> get_in(nested, rest)
      nested when is_list(nested) -> get_in(nested, rest)
      _ -> nil
    end
  end

  defp capture_snapshot do
    default_monitored_keys()
    |> Enum.reduce(%{}, fn {app, keys}, acc ->
      app_map = Map.new(keys, fn key_path ->
        {key_path, get_live(app, key_path)}
      end)
      Map.put(acc, app, app_map)
    end)
  end

  defp default_monitored_keys do
    Application.get_env(:my_app, :config_drift_monitored_keys, [])
  end
end
```
