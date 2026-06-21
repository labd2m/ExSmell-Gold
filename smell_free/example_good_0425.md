# File: `example_good_425.md`

```elixir
defmodule Telemetry.SampledRecorder do
  @moduledoc """
  GenServer that attaches to telemetry events and records a
  statistically representative sample of measurements, rather than
  every occurrence, to reduce overhead for high-frequency events.

  The sample rate is configurable per event type. Samples are stored
  in a bounded ring buffer per event and exposed for aggregation or
  export on demand.
  """

  use GenServer

  require Logger

  @default_sample_rate 0.1
  @default_buffer_size 500

  @type event_name :: [atom()]
  @type sample_rate :: float()

  @type event_config :: %{
          required(:event_name) => event_name(),
          optional(:sample_rate) => sample_rate(),
          optional(:buffer_size) => pos_integer()
        }

  @type sample :: %{
          measurements: map(),
          metadata: map(),
          recorded_at: integer()
        }

  @doc false
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns all buffered samples for a given event name.
  """
  @spec samples(event_name()) :: [sample()]
  def samples(event_name) when is_list(event_name) do
    GenServer.call(__MODULE__, {:samples, event_name})
  end

  @doc """
  Returns the total count of events seen (sampled + dropped) for an event.
  """
  @spec event_count(event_name()) :: non_neg_integer()
  def event_count(event_name) when is_list(event_name) do
    GenServer.call(__MODULE__, {:event_count, event_name})
  end

  @doc """
  Clears the sample buffer for a given event.
  """
  @spec clear(event_name()) :: :ok
  def clear(event_name) when is_list(event_name) do
    GenServer.cast(__MODULE__, {:clear, event_name})
  end

  @doc false
  def handle_telemetry_event(event_name, measurements, metadata, %{pid: pid}) do
    send(pid, {:telemetry_event, event_name, measurements, metadata})
  end

  @impl GenServer
  def init(opts) do
    events = Keyword.fetch!(opts, :events)
    default_sample_rate = Keyword.get(opts, :default_sample_rate, @default_sample_rate)

    state = %{buffers: %{}, counts: %{}, configs: %{}}

    final_state =
      Enum.reduce(events, state, fn config, acc ->
        event_name = config.event_name
        sample_rate = Map.get(config, :sample_rate, default_sample_rate)
        buffer_size = Map.get(config, :buffer_size, @default_buffer_size)

        :telemetry.attach(
          handler_id(event_name),
          event_name,
          &__MODULE__.handle_telemetry_event/4,
          %{pid: self()}
        )

        acc
        |> put_in([:buffers, event_name], :queue.new())
        |> put_in([:counts, event_name], 0)
        |> put_in([:configs, event_name], %{sample_rate: sample_rate, buffer_size: buffer_size})
      end)

    {:ok, final_state}
  end

  @impl GenServer
  def handle_call({:samples, event_name}, _from, state) do
    samples =
      state.buffers
      |> Map.get(event_name, :queue.new())
      |> :queue.to_list()

    {:reply, samples, state}
  end

  @impl GenServer
  def handle_call({:event_count, event_name}, _from, state) do
    {:reply, Map.get(state.counts, event_name, 0), state}
  end

  @impl GenServer
  def handle_cast({:clear, event_name}, state) do
    {:noreply, put_in(state, [:buffers, event_name], :queue.new())}
  end

  @impl GenServer
  def handle_info({:telemetry_event, event_name, measurements, metadata}, state) do
    config = Map.get(state.configs, event_name, %{sample_rate: @default_sample_rate, buffer_size: @default_buffer_size})
    new_count = Map.get(state.counts, event_name, 0) + 1
    state_with_count = put_in(state, [:counts, event_name], new_count)

    if :rand.uniform() <= config.sample_rate do
      sample = %{measurements: measurements, metadata: metadata, recorded_at: System.monotonic_time(:millisecond)}
      current = Map.get(state_with_count.buffers, event_name, :queue.new())
      trimmed = if :queue.len(current) >= config.buffer_size, do: elem(:queue.out(current), 1), else: current
      updated = :queue.in(sample, trimmed)
      {:noreply, put_in(state_with_count, [:buffers, event_name], updated)}
    else
      {:noreply, state_with_count}
    end
  end

  @impl GenServer
  def terminate(_reason, state) do
    Enum.each(state.configs, fn {event_name, _} ->
      :telemetry.detach(handler_id(event_name))
    end)
  end

  defp handler_id(event_name) do
    "#{__MODULE__}:#{Enum.join(event_name, ".")}"
  end
end
```
