```elixir
defmodule BinaryCodec do
  def encode_term(term) do
    :erlang.term_to_binary(term, [:compressed])
  end

  def decode_term(binary) do
    :erlang.binary_to_term(binary, [:safe])
  rescue
    _ -> {:error, :decode_failed}
  end

  def checksum(binary) when is_binary(binary) do
    :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)
  end

  def encode_json(term) do
    term
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
    |> :json.encode()
    |> IO.iodata_to_binary()
  end
end

defmodule SerializationHelpers do
  defmacro __using__(_opts) do
    quote do
      import BinaryCodec

      def wrap_event(event, stream_id, version) do
        %{
          stream_id:  stream_id,
          version:    version,
          event_type: event.__struct__ |> to_string() |> String.split(".") |> List.last(),
          payload:    Map.from_struct(event),
          inserted_at: DateTime.utc_now()
        }
      end

      def apply_migration(event, from_version, to_version) when from_version < to_version do
        {:ok, Map.put(event, :schema_version, to_version)}
      end
      def apply_migration(event, _from, _to), do: {:ok, event}
    end
  end
end

defmodule EventStore do
  use SerializationHelpers

  @current_schema_version 3
  @max_batch_size         500

  def append(stream_id, events, opts \\ []) when is_list(events) do
    expected_version = Keyword.get(opts, :expected_version, :any)

    encoded =
      events
      |> Enum.with_index(1)
      |> Enum.map(fn {event, offset} ->
        wrapped  = wrap_event(event, stream_id, offset)
        payload  = encode_term(wrapped)
        %{
          stream_id:      stream_id,
          version:        offset,
          event_type:     wrapped.event_type,
          payload:        payload,
          payload_json:   encode_json(wrapped.payload),
          checksum:       checksum(payload),
          schema_version: @current_schema_version,
          inserted_at:    DateTime.utc_now()
        }
      end)

    {:ok, %{stream_id: stream_id, appended: length(encoded), expected_version: expected_version, events: encoded}}
  end

  def project(stream_id, raw_events) do
    Enum.reduce(raw_events, %{stream_id: stream_id, state: %{}, version: 0}, fn raw, acc ->
      case decode_event(raw) do
        {:ok, event} ->
          %{acc | state: apply_event(acc.state, event), version: raw.version}
        {:error, reason} ->
          acc
          |> Map.update(:errors, [reason], &[reason | &1])
      end
    end)
  end

  def reconstruct(stream_id, raw_events) do
    raw_events
    |> Enum.map(&decode_event/1)
    |> Enum.filter(&match?({:ok, _}, &1))
    |> Enum.map(fn {:ok, e} -> e end)
    |> then(fn events -> {:ok, %{stream_id: stream_id, events: events, count: length(events)}} end)
  end

  def verify_integrity(stored_event) do
    recomputed = checksum(stored_event.payload)
    if recomputed == stored_event.checksum,
      do: :ok,
      else: {:error, "Checksum mismatch for event at version #{stored_event.version}"}
  end

  def batch_append(stream_id, events) when length(events) > @max_batch_size do
    events
    |> Enum.chunk_every(@max_batch_size)
    |> Enum.reduce({:ok, []}, fn batch, {:ok, acc} ->
      case append(stream_id, batch) do
        {:ok, result} -> {:ok, acc ++ [result]}
        err           -> err
      end
    end)
  end
  def batch_append(stream_id, events), do: append(stream_id, events)

  defp decode_event(%{payload: payload, schema_version: sv}) do
    with decoded when not is_tuple(decoded) <- decode_term(payload),
         {:ok, migrated} <- apply_migration(decoded, sv, @current_schema_version) do
      {:ok, migrated}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_event(state, event) do
    Map.merge(state, Map.get(event, :payload, %{}))
  end
end
```
