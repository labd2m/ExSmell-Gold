```elixir
defmodule Relay.TaskPool do
  @moduledoc """
  A DynamicSupervisor-backed pool for dispatching and supervising transient
  job workers. Capacity limits are enforced at the supervisor level, and each
  worker process is linked into the supervision tree for full lifecycle control.
  """

  use Supervisor

  alias Relay.TaskPool.Worker

  @type opt :: {:max_children, pos_integer()}
  @type dispatch_result :: {:ok, pid()} | {:error, :max_children | term()}

  @spec start_link([opt()]) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(opts) do
    max_children = Keyword.get(opts, :max_children, 50)

    children = [
      {Registry, keys: :unique, name: Relay.TaskPool.Registry},
      {DynamicSupervisor,
       name: Relay.TaskPool.Supervisor,
       strategy: :one_for_one,
       max_children: max_children}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc """
  Dispatches a `payload` to a new transient worker process.

  Accepts an optional `reply_to` pid; upon completion the worker sends
  `{:worker_result, result}` to that process. Returns `{:ok, pid}` or
  `{:error, reason}`.
  """
  @spec dispatch(term(), keyword()) :: dispatch_result()
  def dispatch(payload, opts \\ []) do
    spec = Worker.child_spec(payload: payload, reply_to: Keyword.get(opts, :reply_to))
    DynamicSupervisor.start_child(Relay.TaskPool.Supervisor, spec)
  end

  @doc "Returns the pids of all currently running workers."
  @spec active_workers() :: [pid()]
  def active_workers do
    Relay.TaskPool.Supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.flat_map(fn
      {_, pid, :worker, _} when is_pid(pid) -> [pid]
      _ -> []
    end)
  end

  @doc "Returns the current count of active workers."
  @spec active_count() :: non_neg_integer()
  def active_count, do: length(active_workers())
end

defmodule Relay.TaskPool.Worker do
  @moduledoc """
  A transient GenServer worker that processes a single submitted payload.

  Stops with `:normal` on success and `{:shutdown, reason}` on failure,
  allowing the DynamicSupervisor to apply its configured restart strategy.
  """

  use GenServer, restart: :transient

  require Logger

  @type state :: %{payload: term(), reply_to: pid() | nil}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl GenServer
  def init(opts) do
    state = %{
      payload: Keyword.fetch!(opts, :payload),
      reply_to: Keyword.get(opts, :reply_to)
    }

    {:ok, state, {:continue, :run}}
  end

  @impl GenServer
  def handle_continue(:run, %{payload: payload, reply_to: reply_to} = state) do
    payload
    |> execute()
    |> settle(reply_to, state)
  end

  defp execute(%{action: :transform, data: data}) when is_list(data) do
    {:ok, Enum.map(data, &enrich/1)}
  end

  defp execute(%{action: :validate, data: data}) when is_map(data) do
    {:ok, Map.put(data, :validated_at, DateTime.utc_now())}
  end

  defp execute(other) do
    {:error, {:unsupported_payload, other}}
  end

  defp enrich(item) when is_map(item), do: Map.put(item, :processed, true)
  defp enrich(item), do: item

  defp settle({:ok, result}, reply_to, state) do
    dispatch_reply(reply_to, {:ok, result})
    {:stop, :normal, state}
  end

  defp settle({:error, reason}, reply_to, state) do
    Logger.warning("[TaskPool.Worker] Execution failed", reason: inspect(reason))
    dispatch_reply(reply_to, {:error, reason})
    {:stop, {:shutdown, reason}, state}
  end

  defp dispatch_reply(nil, _result), do: :ok
  defp dispatch_reply(pid, result) when is_pid(pid), do: send(pid, {:worker_result, result})
end
```
