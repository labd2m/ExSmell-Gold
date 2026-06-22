```elixir
defmodule Jobqueue.Broker do
  @moduledoc """
  In-process job queue GenServer with configurable capacity and
  backpressure. Producers call `enqueue/2`, which blocks when the
  queue is at capacity. Consumers pull jobs via `dequeue/1`.
  """

  use GenServer

  @type job :: %{id: String.t(), type: atom(), payload: map(), enqueued_at: DateTime.t()}
  @type state :: %{
          queue: :queue.queue(),
          capacity: pos_integer(),
          size: non_neg_integer(),
          waiting_producers: [{GenServer.from(), job()}]
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec enqueue(atom(), map(), keyword()) :: :ok | {:error, :timeout}
  def enqueue(job_type, payload, opts \\ [])
      when is_atom(job_type) and is_map(payload) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    name = Keyword.get(opts, :queue, __MODULE__)

    job = %{
      id: generate_id(),
      type: job_type,
      payload: payload,
      enqueued_at: DateTime.utc_now()
    }

    GenServer.call(name, {:enqueue, job}, timeout)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @spec dequeue(keyword()) :: {:ok, job()} | {:error, :empty}
  def dequeue(opts \\ []) do
    name = Keyword.get(opts, :queue, __MODULE__)
    GenServer.call(name, :dequeue)
  end

  @spec queue_size(keyword()) :: non_neg_integer()
  def queue_size(opts \\ []) do
    name = Keyword.get(opts, :queue, __MODULE__)
    GenServer.call(name, :size)
  end

  @impl GenServer
  def init(opts) do
    state = %{
      queue: :queue.new(),
      capacity: Keyword.get(opts, :capacity, 1000),
      size: 0,
      waiting_producers: []
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:enqueue, job}, from, %{size: size, capacity: cap} = state) when size >= cap do
    updated = %{state | waiting_producers: state.waiting_producers ++ [{from, job}]}
    {:noreply, updated}
  end

  def handle_call({:enqueue, job}, _from, state) do
    updated = %{state | queue: :queue.in(job, state.queue), size: state.size + 1}
    {:reply, :ok, updated}
  end

  @impl GenServer
  def handle_call(:dequeue, _from, state) do
    case :queue.out(state.queue) do
      {:empty, _} ->
        {:reply, {:error, :empty}, state}

      {{:value, job}, rest} ->
        {new_state, replies} = admit_waiting_producers(%{state | queue: rest, size: state.size - 1})
        Enum.each(replies, fn {from, result} -> GenServer.reply(from, result) end)
        {:reply, {:ok, job}, new_state}
    end
  end

  @impl GenServer
  def handle_call(:size, _from, state) do
    {:reply, state.size, state}
  end

  @spec admit_waiting_producers(state()) :: {state(), [{GenServer.from(), :ok}]}
  defp admit_waiting_producers(%{waiting_producers: []} = state), do: {state, []}

  defp admit_waiting_producers(%{waiting_producers: [{from, job} | rest]} = state) do
    new_state = %{
      state
      | queue: :queue.in(job, state.queue),
        size: state.size + 1,
        waiting_producers: rest
    }

    {new_state, [{from, :ok}]}
  end

  @spec generate_id() :: String.t()
  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end

defmodule Jobqueue.BrokerSupervisor do
  @moduledoc """
  Supervisor for named Jobqueue.Broker instances.
  Supports starting multiple named queues with isolated configurations.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(opts) do
    queues = Keyword.get(opts, :queues, [[name: Jobqueue.Broker, capacity: 500]])

    children = Enum.map(queues, fn queue_opts ->
      Supervisor.child_spec({Jobqueue.Broker, queue_opts}, id: Keyword.fetch!(queue_opts, :name))
    end)

    Supervisor.init(children, strategy: :one_for_one)
  end
end
```
