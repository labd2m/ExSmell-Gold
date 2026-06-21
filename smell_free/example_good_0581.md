```elixir
defmodule Platform.JobDeduplicator do
  @moduledoc """
  A GenServer that prevents duplicate job execution by tracking content
  fingerprints of recently submitted payloads.

  Before a job is enqueued, its fingerprint is checked against an in-memory
  registry. If the same fingerprint exists and has not yet expired, the
  submission is rejected as a duplicate. This is useful for idempotent
  background work triggered by events that may fire multiple times.
  """

  use GenServer

  require Logger

  @type fingerprint :: String.t()
  @type job_name :: atom()
  @type dedup_result :: {:ok, :submitted} | {:error, :duplicate}

  @default_window_ms :timer.minutes(10)
  @sweep_interval_ms :timer.minutes(2)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Submits a job if no matching fingerprint has been seen within the dedup window.

  `submit_fn` is called only when the submission is not a duplicate.
  Returns `{:ok, :submitted}` or `{:error, :duplicate}`.
  """
  @spec submit(job_name(), map(), (-> :ok | {:error, term()}), keyword()) :: dedup_result()
  def submit(job_name, payload, submit_fn, opts \\ [])
      when is_atom(job_name) and is_map(payload) and is_function(submit_fn, 0) do
    fingerprint = compute_fingerprint(job_name, payload)
    window_ms = Keyword.get(opts, :window_ms, @default_window_ms)
    GenServer.call(__MODULE__, {:submit, fingerprint, submit_fn, window_ms})
  end

  @doc "Checks whether a payload has already been seen without submitting."
  @spec duplicate?(job_name(), map()) :: boolean()
  def duplicate?(job_name, payload) when is_atom(job_name) and is_map(payload) do
    fingerprint = compute_fingerprint(job_name, payload)
    GenServer.call(__MODULE__, {:check, fingerprint})
  end

  @doc "Returns the count of fingerprints currently tracked."
  @spec tracked_count() :: non_neg_integer()
  def tracked_count, do: GenServer.call(__MODULE__, :count)

  @impl GenServer
  def init(opts) do
    window_ms = Keyword.get(opts, :window_ms, @default_window_ms)
    schedule_sweep()
    {:ok, %{registry: %{}, window_ms: window_ms}}
  end

  @impl GenServer
  def handle_call({:submit, fingerprint, submit_fn, window_ms}, _from, state) do
    if known?(state.registry, fingerprint) do
      Logger.debug("[JobDeduplicator] Duplicate suppressed", fingerprint: fingerprint)
      {:reply, {:error, :duplicate}, state}
    else
      case submit_fn.() do
        :ok ->
          new_registry = Map.put(state.registry, fingerprint, expires_at(window_ms))
          {:reply, {:ok, :submitted}, %{state | registry: new_registry}}

        {:ok, _} ->
          new_registry = Map.put(state.registry, fingerprint, expires_at(window_ms))
          {:reply, {:ok, :submitted}, %{state | registry: new_registry}}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  @impl GenServer
  def handle_call({:check, fingerprint}, _from, state) do
    {:reply, known?(state.registry, fingerprint), state}
  end

  @impl GenServer
  def handle_call(:count, _from, state) do
    {:reply, map_size(state.registry), state}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    current = now_ms()
    fresh = Map.reject(state.registry, fn {_, exp} -> exp < current end)
    schedule_sweep()
    {:noreply, %{state | registry: fresh}}
  end

  defp known?(registry, fingerprint) do
    case Map.get(registry, fingerprint) do
      nil -> false
      exp -> exp >= now_ms()
    end
  end

  defp compute_fingerprint(job_name, payload) do
    content = Jason.encode!(%{job: job_name, payload: payload})
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  defp expires_at(window_ms), do: now_ms() + window_ms
  defp now_ms, do: :erlang.system_time(:millisecond)
  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end
```
