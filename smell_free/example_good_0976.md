```elixir
defmodule Http.StreamingJsonParser do
  @moduledoc """
  Parses large JSON responses from external APIs without buffering the
  complete body in memory. The parser wraps a `Req` response stream and
  emits individual JSON objects as they become complete, enabling downstream
  processing to begin before the HTTP response has finished transferring.
  Designed for APIs that return newline-delimited JSON (NDJSON) or
  JSON arrays streamed across multiple chunks.
  """

  require Logger

  @type parser_opts :: [
          format: :ndjson | :json_array,
          max_object_bytes: pos_integer()
        ]

  @default_max_object_bytes 10 * 1024 * 1024

  @doc """
  Returns a `Stream.t()` of decoded maps from `url`. Each element is a
  parsed JSON object. The stream is lazy; the HTTP request is opened only
  when the stream is consumed.

  `:format` controls parsing behaviour:
  - `:ndjson` — newline-delimited JSON, one object per line
  - `:json_array` — a top-level JSON array emitted across chunks
  """
  @spec stream(binary(), keyword(), parser_opts()) :: Enumerable.t()
  def stream(url, req_opts \\ [], opts \\ []) do
    format = Keyword.get(opts, :format, :ndjson)
    max_bytes = Keyword.get(opts, :max_object_bytes, @default_max_object_bytes)

    Stream.resource(
      fn -> open_response(url, req_opts) end,
      fn state -> next_object(state, format, max_bytes) end,
      fn state -> close_response(state) end
    )
  end

  @doc """
  Collects all objects from `url` into a list. Convenience wrapper around
  `stream/3` for moderate-sized responses where full materialisation is acceptable.
  """
  @spec fetch_all(binary(), keyword(), parser_opts()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_all(url, req_opts \\ [], opts \\ []) do
    objects =
      url
      |> stream(req_opts, opts)
      |> Enum.to_list()

    {:ok, objects}
  rescue
    e -> {:error, Exception.message(e)}
  end

  # ---------------------------------------------------------------------------
  # Private stream resource callbacks
  # ---------------------------------------------------------------------------

  defp open_response(url, req_opts) do
    case Req.get(url, Keyword.merge(req_opts, into: :self)) do
      {:ok, %Req.Response{status: 200} = resp} ->
        %{response: resp, buffer: "", done: false}

      {:ok, %Req.Response{status: status}} ->
        raise "Unexpected HTTP status #{status} from #{url}"

      {:error, reason} ->
        raise "HTTP request failed: #{inspect(reason)}"
    end
  end

  defp next_object(%{done: true, buffer: ""} = state, _format, _max_bytes) do
    {:halt, state}
  end

  defp next_object(%{done: true, buffer: buf} = state, :ndjson, _max_bytes) do
    parse_remaining_ndjson(buf, state)
  end

  defp next_object(%{done: true, buffer: buf} = state, :json_array, _max_bytes) do
    parse_remaining_array(buf, state)
  end

  defp next_object(state, format, max_bytes) do
    receive do
      {:data, chunk} when byte_size(state.buffer) + byte_size(chunk) > max_bytes ->
        raise "JSON object exceeded maximum size of #{max_bytes} bytes"

      {:data, chunk} ->
        new_buffer = state.buffer <> chunk
        extract_objects(format, new_buffer, %{state | buffer: new_buffer})

      :done ->
        {:[], %{state | done: true}}

      {:error, reason} ->
        raise "Stream error: #{inspect(reason)}"
    after
      30_000 -> {:halt, state}
    end
  end

  defp extract_objects(:ndjson, buffer, state) do
    lines = String.split(buffer, "\n")

    case List.pop_at(lines, -1) do
      {last, complete_lines} ->
        objects = Enum.flat_map(complete_lines, &decode_line/1)
        {objects, %{state | buffer: last}}
    end
  end

  defp extract_objects(:json_array, buffer, state) do
    case extract_array_object(buffer) do
      {nil, _} -> {[], state}
      {object, rest} -> {[object], %{state | buffer: rest}}
    end
  end

  defp decode_line(""), do: []
  defp decode_line(line) do
    case Jason.decode(line) do
      {:ok, map} -> [map]
      {:error, _} ->
        Logger.warning("Failed to parse NDJSON line", line: String.slice(line, 0, 100))
        []
    end
  end

  defp extract_array_object(buffer) do
    stripped = String.trim_leading(buffer, " \n\t[,")

    case Jason.decode_stream(stripped) do
      {:ok, object, rest} -> {object, rest}
      _ -> {nil, buffer}
    end
  end

  defp parse_remaining_ndjson(buffer, state) do
    objects = decode_line(String.trim(buffer))
    {objects, %{state | buffer: ""}}
  end

  defp parse_remaining_array(buffer, state) do
    {obj, rest} = extract_array_object(buffer)
    if obj, do: {[obj], %{state | buffer: rest}}, else: {:halt, state}
  end

  defp close_response(_state), do: :ok
end
```
