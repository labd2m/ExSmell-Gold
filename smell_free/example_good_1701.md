```elixir
defmodule Streaming.FrameBuffer do
  @moduledoc """
  Fixed-size circular frame buffer for real-time video stream processing.
  Maintains ordered frames with sequence-number tracking and overflow eviction.
  """

  @type frame :: %{seq: non_neg_integer(), data: binary(), captured_at: integer()}
  @type t :: %__MODULE__{
    capacity: pos_integer(),
    frames: :queue.queue(),
    size: non_neg_integer(),
    head_seq: non_neg_integer(),
    dropped: non_neg_integer()
  }

  defstruct [:capacity, :frames, :size, :head_seq, :dropped]

  @spec new(pos_integer()) :: t()
  def new(capacity) when is_integer(capacity) and capacity > 0 do
    %__MODULE__{
      capacity: capacity,
      frames: :queue.new(),
      size: 0,
      head_seq: 0,
      dropped: 0
    }
  end

  @spec push(t(), binary()) :: t()
  def push(%__MODULE__{} = buffer, data) when is_binary(data) do
    frame = %{seq: buffer.head_seq, data: data, captured_at: System.monotonic_time(:millisecond)}
    enqueue_frame(buffer, frame)
  end

  @spec pop(t()) :: {:ok, frame(), t()} | {:error, :empty}
  def pop(%__MODULE__{size: 0}), do: {:error, :empty}

  def pop(%__MODULE__{} = buffer) do
    {{:value, frame}, rest} = :queue.out(buffer.frames)
    updated = %{buffer | frames: rest, size: buffer.size - 1}
    {:ok, frame, updated}
  end

  @spec peek(t()) :: {:ok, frame()} | {:error, :empty}
  def peek(%__MODULE__{size: 0}), do: {:error, :empty}

  def peek(%__MODULE__{} = buffer) do
    {:value, frame} = :queue.peek(buffer.frames)
    {:ok, frame}
  end

  @spec drain(t()) :: {[frame()], t()}
  def drain(%__MODULE__{} = buffer) do
    frames = buffer.frames |> :queue.to_list()
    empty_buffer = %{buffer | frames: :queue.new(), size: 0}
    {frames, empty_buffer}
  end

  @spec full?(t()) :: boolean()
  def full?(%__MODULE__{size: size, capacity: cap}), do: size >= cap

  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{size: 0}), do: true
  def empty?(%__MODULE__{}), do: false

  @spec stats(t()) :: %{size: non_neg_integer(), capacity: pos_integer(), dropped: non_neg_integer(), utilization: float()}
  def stats(%__MODULE__{size: size, capacity: cap, dropped: dropped}) do
    %{size: size, capacity: cap, dropped: dropped, utilization: size / cap}
  end

  @spec enqueue_frame(t(), frame()) :: t()
  defp enqueue_frame(%__MODULE__{size: size, capacity: cap} = buffer, frame)
       when size >= cap do
    {_, evicted_queue} = :queue.out(buffer.frames)
    new_queue = :queue.in(frame, evicted_queue)
    %{buffer | frames: new_queue, head_seq: buffer.head_seq + 1, dropped: buffer.dropped + 1}
  end

  defp enqueue_frame(%__MODULE__{} = buffer, frame) do
    new_queue = :queue.in(frame, buffer.frames)
    %{buffer | frames: new_queue, size: buffer.size + 1, head_seq: buffer.head_seq + 1}
  end
end
```
