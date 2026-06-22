```elixir
defmodule Crawler.Supervisor do
  @moduledoc """
  Supervision tree for a configurable pool of web crawler workers.
  The tree uses a `:rest_for_one` strategy so a crash in the URL frontier
  also restarts downstream workers that depend on it, while a single worker
  crash does not affect the frontier or sibling workers. Worker count is
  configurable at runtime via `resize_pool/1` without restarting the tree.
  """

  use Supervisor

  require Logger

  @default_worker_count 5

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Resizes the worker pool to `count` workers. Excess workers are gracefully
  stopped; missing workers are started immediately. Returns `:ok`.
  """
  @spec resize_pool(pos_integer()) :: :ok
  def resize_pool(count) when is_integer(count) and count > 0 do
    Crawler.WorkerPoolSupervisor.resize(count)
  end

  @impl Supervisor
  def init(opts) do
    worker_count = Keyword.get(opts, :worker_count, @default_worker_count)
    concurrency = Keyword.get(opts, :fetch_concurrency, 10)

    children = [
      # URL frontier holds the queue of pending URLs — all workers depend on it.
      {Crawler.UrlFrontier, name: Crawler.UrlFrontier},

      # HTTP fetch pool shared by all crawler workers.
      {Task.Supervisor, name: Crawler.FetchSupervisor, max_children: concurrency},

      # Dynamic supervisor for the worker pool; restarted if frontier crashes.
      {Crawler.WorkerPoolSupervisor, initial_count: worker_count},

      # Result writer processes crawled pages downstream of workers.
      {Crawler.ResultWriter, name: Crawler.ResultWriter}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end

defmodule Crawler.WorkerPoolSupervisor do
  @moduledoc """
  DynamicSupervisor that manages individual crawler workers. Supports
  runtime resizing without touching the parent supervision tree.
  """

  use DynamicSupervisor

  require Logger

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    initial_count = Keyword.get(opts, :initial_count, 1)
    {:ok, pid} = DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
    Enum.each(1..initial_count, fn _ -> start_worker() end)
    {:ok, pid}
  end

  @spec resize(pos_integer()) :: :ok
  def resize(target_count) when is_integer(target_count) and target_count > 0 do
    current = DynamicSupervisor.which_children(__MODULE__) |> length()

    cond do
      target_count > current ->
        Enum.each(1..(target_count - current), fn _ -> start_worker() end)
        Logger.info("Crawler pool scaled up", from: current, to: target_count)

      target_count < current ->
        excess = current - target_count

        DynamicSupervisor.which_children(__MODULE__)
        |> Enum.take(excess)
        |> Enum.each(fn {_, pid, _, _} ->
          DynamicSupervisor.terminate_child(__MODULE__, pid)
        end)

        Logger.info("Crawler pool scaled down", from: current, to: target_count)

      true ->
        :ok
    end

    :ok
  end

  @impl DynamicSupervisor
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  defp start_worker do
    DynamicSupervisor.start_child(__MODULE__, Crawler.Worker)
  end
end

defmodule Crawler.Worker do
  @moduledoc """
  A single crawler worker that repeatedly claims URLs from the frontier,
  fetches them via the shared HTTP pool, extracts links and content,
  and delivers results to the writer. Runs an indefinite loop until
  the frontier signals shutdown.
  """

  use GenServer

  require Logger

  @impl GenServer
  def init(_opts) do
    send(self(), :next_url)
    {:ok, %{processed: 0}}
  end

  def child_spec(_opts) do
    %{id: make_ref(), start: {__MODULE__, :start_link, [[]]}, restart: :permanent}
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl GenServer
  def handle_info(:next_url, state) do
    case Crawler.UrlFrontier.claim() do
      {:ok, url} ->
        process_url(url)
        send(self(), :next_url)
        {:noreply, %{state | processed: state.processed + 1}}

      :empty ->
        Process.send_after(self(), :next_url, 500)
        {:noreply, state}

      :shutdown ->
        {:stop, :normal, state}
    end
  end

  defp process_url(url) do
    Task.Supervisor.async_nolink(Crawler.FetchSupervisor, fn ->
      with {:ok, body} <- Crawler.Fetcher.get(url),
           {:ok, result} <- Crawler.Parser.parse(url, body) do
        Crawler.UrlFrontier.enqueue_many(result.links)
        Crawler.ResultWriter.write(result)
      end
    end)
    |> Task.await(30_000)
  rescue
    e -> Logger.warning("Crawl failed", url: url, reason: Exception.message(e))
  end
end
```
