```elixir
defmodule Transport.Frame do
  @moduledoc """
  Represents a single transport frame carrying a typed binary payload.
  """

  @type message_type ::
          :ping
          | :pong
          | :data
          | :ack
          | :error

  @type t :: %__MODULE__{
          type: message_type(),
          sequence: non_neg_integer(),
          payload: binary()
        }

  defstruct [:type, :sequence, :payload]
end

defmodule Transport.Protocol do
  @moduledoc """
  Encodes and decodes length-prefixed binary frames for a TCP transport layer.

  Frame wire format (all big-endian):
    - 4 bytes: total frame length (excluding this header)
    - 1 byte:  message type tag
    - 4 bytes: sequence number
    - N bytes: payload body

  `decode_stream/2` is designed for incremental parsing: it consumes as many
  complete frames as possible from a binary buffer and returns remaining bytes
  for the next call, making it suitable for use in a `GenServer` socket reader.
  """

  alias Transport.Frame

  @type_tags %{
    ping: 0x01,
    pong: 0x02,
    data: 0x03,
    ack: 0x04,
    error: 0x05
  }

  @tag_types Map.new(@type_tags, fn {k, v} -> {v, k} end)

  @header_size 5

  @spec encode(Frame.t()) :: binary()
  def encode(%Frame{type: type, sequence: seq, payload: payload}) do
    type_tag = Map.fetch!(@type_tags, type)
    body = <<type_tag::8, seq::32, payload::binary>>
    <<byte_size(body)::32, body::binary>>
  end

  @spec decode(binary()) ::
          {:ok, Frame.t(), binary()}
          | {:error, :incomplete_frame}
          | {:error, {:unknown_type, integer()}}
  def decode(<<length::32, rest::binary>>) when byte_size(rest) >= length do
    <<frame_body::binary-size(length), remaining::binary>> = rest
    parse_body(frame_body, remaining)
  end

  def decode(_buffer), do: {:error, :incomplete_frame}

  @spec decode_stream(binary(), [Frame.t()]) :: {[Frame.t()], binary()}
  def decode_stream(buffer, acc \\ []) do
    case decode(buffer) do
      {:ok, frame, remaining} ->
        decode_stream(remaining, [frame | acc])

      {:error, :incomplete_frame} ->
        {Enum.reverse(acc), buffer}

      {:error, {:unknown_type, _tag}} ->
        {Enum.reverse(acc), buffer}
    end
  end

  @spec ping(non_neg_integer()) :: binary()
  def ping(sequence), do: encode(%Frame{type: :ping, sequence: sequence, payload: <<>>})

  @spec pong(non_neg_integer()) :: binary()
  def pong(sequence), do: encode(%Frame{type: :pong, sequence: sequence, payload: <<>>})

  @spec data(non_neg_integer(), binary()) :: binary()
  def data(sequence, payload) when is_binary(payload) do
    encode(%Frame{type: :data, sequence: sequence, payload: payload})
  end

  @spec ack(non_neg_integer()) :: binary()
  def ack(sequence), do: encode(%Frame{type: :ack, sequence: sequence, payload: <<>>})

  defp parse_body(<<type_tag::8, sequence::32, payload::binary>>, remaining) do
    case Map.fetch(@tag_types, type_tag) do
      {:ok, type} ->
        {:ok, %Frame{type: type, sequence: sequence, payload: payload}, remaining}

      :error ->
        {:error, {:unknown_type, type_tag}}
    end
  end

  defp parse_body(_malformed, _remaining), do: {:error, :incomplete_frame}
end
```
