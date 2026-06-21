```elixir
defmodule MyApp.Devices.TelemetryIngester do
  @moduledoc """
  Ingests device telemetry payloads arriving over a TCP socket, validates
  each frame against a typed schema, and forwards clean readings to the
  `device_readings` table via batched inserts. Frames that fail validation
  are routed to a dead-letter store for investigation rather than silently
  dropped.

  The ingest loop runs inside a supervised `Task` started from
  `MyApp.Devices.TelemetryListener`.
  """

  require Logger

  alias MyApp.Repo
  alias MyApp.Devices.{DeviceReading, DeadLetterReading}

  @batch_size 100
  @flush_interval_ms 2_000

  @type raw_frame :: binary()
  @type validated_reading :: %{
          device_id: String.t(),
          metric: String.t(),
          value: float(),
          unit: String.t(),
          recorded_at: DateTime.t()
        }

  @doc """
  Starts the ingestion loop on `socket`. Reads frames, validates them,
  and flushes accumulated batches every `#{@flush_interval_ms}` ms or
  when `#{@batch_size}` frames have been collected.
  """
  @spec run(:gen_tcp.socket()) :: :ok
  def run(socket) do
    loop(socket, [], System.monotonic_time(:millisecond))
  end

  @spec loop(:gen_tcp.socket(), [validated_reading()], integer()) :: :ok
  defp loop(socket, batch, last_flush_ms) do
    case :gen_tcp.recv(socket, 0, 1_000) do
      {:ok, frame} ->
        {new_batch, new_flush_ms} =
          frame
          |> parse_and_validate()
          |> accumulate(batch, last_flush_ms)

        loop(socket, new_batch, new_flush_ms)

      {:error, :timeout} ->
        {new_batch, new_flush_ms} = maybe_flush(batch, last_flush_ms, force: false)
        loop(socket, new_batch, new_flush_ms)

      {:error, :closed} ->
        flush_batch(batch)
        Logger.info("telemetry_ingester_socket_closed")
        :ok

      {:error, reason} ->
        flush_batch(batch)
        Logger.error("telemetry_ingester_socket_error", reason: inspect(reason))
        :ok
    end
  end

  @spec parse_and_validate(raw_frame()) ::
          {:ok, validated_reading()} | {:error, term(), raw_frame()}
  defp parse_and_validate(frame) do
    with {:ok, map} <- Jason.decode(frame),
         {:ok, reading} <- validate_reading(map) do
      {:ok, reading}
    else
      {:error, reason} -> {:error, reason, frame}
    end
  end

  @spec validate_reading(map()) :: {:ok, validated_reading()} | {:error, :invalid_reading}
  defp validate_reading(%{"device_id" => id, "metric" => m, "value" => v, "unit" => u})
       when is_binary(id) and is_binary(m) and is_number(v) and is_binary(u) do
    {:ok, %{device_id: id, metric: m, value: v * 1.0, unit: u, recorded_at: DateTime.utc_now()}}
  end

  defp validate_reading(_), do: {:error, :invalid_reading}

  @spec accumulate(
          {:ok, validated_reading()} | {:error, term(), raw_frame()},
          [validated_reading()],
          integer()
        ) :: {[validated_reading()], integer()}
  defp accumulate({:ok, reading}, batch, last_flush_ms) do
    new_batch = [reading | batch]
    maybe_flush(new_batch, last_flush_ms, force: length(new_batch) >= @batch_size)
  end

  defp accumulate({:error, reason, frame}, batch, last_flush_ms) do
    store_dead_letter(frame, reason)
    {batch, last_flush_ms}
  end

  @spec maybe_flush([validated_reading()], integer(), keyword()) ::
          {[validated_reading()], integer()}
  defp maybe_flush(batch, last_flush_ms, opts) do
    now = System.monotonic_time(:millisecond)
    elapsed = now - last_flush_ms
    force = Keyword.get(opts, :force, false)

    if force or elapsed >= @flush_interval_ms do
      flush_batch(batch)
      {[], now}
    else
      {batch, last_flush_ms}
    end
  end

  @spec flush_batch([validated_reading()]) :: :ok
  defp flush_batch([]), do: :ok

  defp flush_batch(batch) do
    Repo.insert_all(DeviceReading, Enum.reverse(batch))
    :ok
  end

  @spec store_dead_letter(raw_frame(), term()) :: :ok
  defp store_dead_letter(frame, reason) do
    %DeadLetterReading{}
    |> DeadLetterReading.changeset(%{raw: frame, reason: inspect(reason), arrived_at: DateTime.utc_now()})
    |> Repo.insert()

    :ok
  end
end
```
