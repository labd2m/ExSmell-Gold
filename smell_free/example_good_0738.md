```elixir
defmodule LogTailer do
  @moduledoc """
  Tails a file by polling for new content at a configurable interval,
  broadcasting each new line to registered subscriber processes.

  The tailer tracks the byte offset of the last read position so it
  only delivers genuinely new content. File rotation (detected when the
  file size shrinks below the last offset) is handled by resetting the
  offset to zero and resuming from the top of the new file.
  """

  use GenServer

  require Logger

  @type opts :: [
          path: Path.t(),
          poll_interval_ms: pos_integer()
        ]

  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec subscribe(pid()) :: :ok
  def subscribe(pid \\ self()) when is_pid(pid) do
    GenServer.call(__MODULE__, {:subscribe, pid})
  end

  @spec unsubscribe(pid()) :: :ok
  def unsubscribe(pid \\ self()) when is_pid(pid) do
    GenServer.cast(__MODULE__, {:unsubscribe, pid})
  end

  @spec stats() :: %{path: String.t(), offset: non_neg_integer(), subscribers: non_neg_integer()}
  def stats, do: GenServer.call(__MODULE__, :stats)

  @impl GenServer
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    interval = Keyword.get(opts, :poll_interval_ms, 250)

    state = %{
      path: path,
      offset: initial_offset(path),
      subscribers: [],
      poll_interval_ms: interval
    }

    schedule_poll(interval)
    {:ok, state}
  end

  @impl GenServer
  def handle_call({:subscribe, pid}, _from, state) do
    ref = Process.monitor(pid)
    {:reply, :ok, %{state | subscribers: [{pid, ref} | state.subscribers]}}
  end

  def handle_call(:stats, _from, state) do
    info = %{path: state.path, offset: state.offset, subscribers: length(state.subscribers)}
    {:reply, info, state}
  end

  @impl GenServer
  def handle_cast({:unsubscribe, pid}, state) do
    {matching, rest} = Enum.split_with(state.subscribers, fn {p, _ref} -> p == pid end)
    Enum.each(matching, fn {_p, ref} -> Process.demonitor(ref, [:flush]) end)
    {:noreply, %{state | subscribers: rest}}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    new_state = read_new_content(state)
    schedule_poll(state.poll_interval_ms)
    {:noreply, new_state}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    remaining = Enum.reject(state.subscribers, fn {p, r} -> p == pid and r == ref end)
    {:noreply, %{state | subscribers: remaining}}
  end

  defp read_new_content(state) do
    case File.stat(state.path) do
      {:ok, %File.Stat{size: size}} when size < state.offset ->
        Logger.info("LogTailer: rotation detected for #{state.path}")
        read_new_content(%{state | offset: 0})

      {:ok, %File.Stat{size: size}} when size > state.offset ->
        new_content = read_from_offset(state.path, state.offset)
        lines = String.split(new_content, "\n", trim: true)
        Enum.each(lines, &broadcast(state.subscribers, &1))
        %{state | offset: size}

      _ ->
        state
    end
  end

  defp read_from_offset(path, offset) do
    case File.open(path, [:read, :binary]) do
      {:ok, file} ->
        :file.position(file, offset)
        {:ok, content} = IO.binread(file, :eof) |> then(&{:ok, &1})
        File.close(file)
        content

      _ ->
        ""
    end
  rescue
    _ -> ""
  end

  defp broadcast(subscribers, line) do
    dead = Enum.reject(subscribers, fn {pid, _ref} ->
      Process.alive?(pid) and (send(pid, {:log_line, line}) == :ok)
    end)
    _ = dead
    :ok
  end

  defp initial_offset(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> size
      _ -> 0
    end
  end

  defp schedule_poll(interval), do: Process.send_after(self(), :poll, interval)
end
```
