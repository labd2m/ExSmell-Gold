```elixir
defmodule Search.Document do
  @moduledoc """
  A normalized document ready for indexing into the search backend.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          type: String.t(),
          title: String.t(),
          body: String.t(),
          tags: [String.t()],
          attributes: map(),
          indexed_at: DateTime.t() | nil
        }

  defstruct [:id, :type, :title, :body, :indexed_at, tags: [], attributes: %{}]
end

defmodule Search.Indexer do
  use GenServer

  alias Search.Document

  @moduledoc """
  Buffers incoming documents and flushes them to the search backend in
  batches. Flushing is triggered either by batch size threshold or by
  a periodic timeout, whichever comes first.
  """

  @flush_interval_ms 5_000
  @batch_threshold 50

  @type state :: %{
          buffer: [Document.t()],
          backend: module(),
          flush_timer: reference() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec index(Document.t()) :: :ok
  def index(%Document{} = document) do
    GenServer.cast(__MODULE__, {:index, document})
  end

  @spec flush_now() :: {:ok, non_neg_integer()}
  def flush_now do
    GenServer.call(__MODULE__, :flush)
  end

  @impl GenServer
  def init(opts) do
    backend = Keyword.fetch!(opts, :backend)
    timer = schedule_flush()
    {:ok, %{buffer: [], backend: backend, flush_timer: timer}}
  end

  @impl GenServer
  def handle_cast({:index, document}, state) do
    new_buffer = [document | state.buffer]

    if length(new_buffer) >= @batch_threshold do
      cancel_timer(state.flush_timer)
      count = flush_buffer(new_buffer, state.backend)
      new_timer = schedule_flush()
      {:noreply, %{state | buffer: [], flush_timer: new_timer}}
      |> tap(fn _ -> _ = count end)
      |> elem(1)
      |> then(fn s -> {:noreply, s} end)
    else
      {:noreply, %{state | buffer: new_buffer}}
    end
  end

  @impl GenServer
  def handle_call(:flush, _from, state) do
    cancel_timer(state.flush_timer)
    count = flush_buffer(state.buffer, state.backend)
    new_timer = schedule_flush()
    {:reply, {:ok, count}, %{state | buffer: [], flush_timer: new_timer}}
  end

  @impl GenServer
  def handle_info(:flush, state) do
    flush_buffer(state.buffer, state.backend)
    new_timer = schedule_flush()
    {:noreply, %{state | buffer: [], flush_timer: new_timer}}
  end

  defp flush_buffer([], _backend), do: 0

  defp flush_buffer(documents, backend) do
    batch = Enum.map(documents, &annotate_timestamp/1)
    :ok = backend.bulk_index(batch)
    length(batch)
  end

  defp annotate_timestamp(doc) do
    %{doc | indexed_at: DateTime.utc_now() |> DateTime.truncate(:second)}
  end

  defp schedule_flush do
    Process.send_after(self(), :flush, @flush_interval_ms)
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref)
end
```
