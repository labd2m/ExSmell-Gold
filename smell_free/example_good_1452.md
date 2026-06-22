```elixir
defmodule WorkerPool.Registry do
  @moduledoc false
  def child_spec(_opts) do
    Registry.child_spec(keys: :unique, name: __MODULE__)
  end
end

defmodule WorkerPool.Supervisor do
  use Supervisor

  @moduledoc """
  Manages a fixed-size pool of concurrent job workers under a supervision tree.
  Each worker is registered by index and restarted independently on failure.
  """

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(opts) do
    pool_size = Keyword.fetch!(opts, :pool_size)

    children =
      Enum.map(1..pool_size, fn id ->
        Supervisor.child_spec(
          {WorkerPool.Worker, id: id},
          id: {WorkerPool.Worker, id}
        )
      end)

    Supervisor.init(children, strategy: :one_for_one)
  end
end

defmodule WorkerPool.Worker do
  use GenServer

  @moduledoc """
  A stateful worker process that executes submitted jobs sequentially
  and accumulates lifetime statistics for observability.
  """

  @type job :: %{op: :reverse | :upcase | :word_count, data: binary()}
  @type stats :: %{processed: non_neg_integer(), failed: non_neg_integer()}
  @type state :: %{id: pos_integer(), processed: non_neg_integer(), failed: non_neg_integer()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, id, name: via(id))
  end

  @spec submit(pos_integer(), job()) :: {:ok, term()} | {:error, :unsupported_operation}
  def submit(worker_id, job) do
    GenServer.call(via(worker_id), {:run, job})
  end

  @spec stats(pos_integer()) :: stats()
  def stats(worker_id) do
    GenServer.call(via(worker_id), :stats)
  end

  @impl GenServer
  def init(id) do
    {:ok, %{id: id, processed: 0, failed: 0}}
  end

  @impl GenServer
  def handle_call({:run, job}, _from, state) do
    case execute(job) do
      {:ok, result} ->
        {:reply, {:ok, result}, %{state | processed: state.processed + 1}}

      {:error, reason} ->
        {:reply, {:error, reason}, %{state | failed: state.failed + 1}}
    end
  end

  def handle_call(:stats, _from, state) do
    {:reply, Map.take(state, [:processed, :failed]), state}
  end

  defp execute(%{op: :reverse, data: data}) when is_binary(data) do
    {:ok, String.reverse(data)}
  end

  defp execute(%{op: :upcase, data: data}) when is_binary(data) do
    {:ok, String.upcase(data)}
  end

  defp execute(%{op: :word_count, data: data}) when is_binary(data) do
    count =
      data
      |> String.split(~r/\s+/, trim: true)
      |> length()

    {:ok, count}
  end

  defp execute(_job), do: {:error, :unsupported_operation}

  defp via(id), do: {:via, Registry, {WorkerPool.Registry, {__MODULE__, id}}}
end
```
