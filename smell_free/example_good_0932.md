```elixir
defmodule Mix.Tasks.Events.Replay do
  @moduledoc """
  Replays events from the event store to rebuild one or more read model
  projections from scratch.

  The task truncates the target projection tables, resets their checkpoints,
  and processes all events from position zero. Use this to recover from a
  corrupted read model or to bootstrap a newly added projection.

  ## Usage

      mix events.replay --projection OrderSummary
      mix events.replay --projection OrderSummary --stream orders
      mix events.replay --all

  """

  use Mix.Task

  require Logger

  alias Platform.{EventStore, ReadModelProjector}

  @shortdoc "Replays event store events to rebuild read model projections"

  @registered_projectors [
    Platform.Projectors.OrderSummary,
    Platform.Projectors.CustomerStats,
    Platform.Projectors.InventoryLevels
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [projection: :string, stream: :string, all: :boolean, batch_size: :integer],
        aliases: [p: :projection, s: :stream, a: :all]
      )

    Mix.Task.run("app.start")

    projectors = resolve_projectors(opts)

    if projectors == [] do
      Mix.shell().error("No projectors found. Use --all or --projection <name>.")
      exit({:shutdown, 1})
    end

    stream_id = Keyword.get(opts, :stream)
    batch_size = Keyword.get(opts, :batch_size, 200)

    Mix.shell().info("\n=== Event Replay ===")
    Mix.shell().info("Projectors : #{length(projectors)}")
    Mix.shell().info("Stream     : #{stream_id || "all"}")
    Mix.shell().info("Batch size : #{batch_size}\n")

    Enum.each(projectors, &replay_projector(&1, stream_id, batch_size))
  end

  defp resolve_projectors(opts) do
    cond do
      Keyword.get(opts, :all) ->
        @registered_projectors

      name = Keyword.get(opts, :projection) ->
        find_projector(name)

      true ->
        []
    end
  end

  defp find_projector(name) do
    Enum.filter(@registered_projectors, fn mod ->
      mod |> Module.split() |> List.last() == name
    end)
  end

  defp replay_projector(projector_module, stream_id, batch_size) do
    name = projector_module |> Module.split() |> List.last()
    Mix.shell().info("Replaying: #{name}")

    Mix.shell().info("  Resetting checkpoint...")
    ReadModelProjector.Checkpoint.save(projector_module, 0)

    Mix.shell().info("  Truncating projection tables...")
    projector_module.reset!()

    Mix.shell().info("  Replaying events...")
    {events_processed, duration_ms} = timed(fn -> process_all(projector_module, stream_id, batch_size) end)

    Mix.shell().info("  Done: #{events_processed} events in #{duration_ms}ms\n")
  end

  defp process_all(projector_module, stream_id, batch_size) do
    stream_ids = if stream_id, do: [stream_id], else: list_all_stream_ids()

    Enum.reduce(stream_ids, 0, fn sid, total ->
      events = EventStore.read_stream(sid, from_version: 0, limit: :infinity)

      events
      |> Stream.chunk_every(batch_size)
      |> Enum.each(fn batch ->
        Enum.each(batch, fn event ->
          projector_module.handle_event(event)
        end)
      end)

      total + length(events)
    end)
  end

  defp list_all_stream_ids do
    import Ecto.Query
    from(e in Platform.EventStore.StoredEvent, distinct: e.stream_id, select: e.stream_id)
    |> Platform.Repo.all()
  end

  defp timed(fun) do
    start = System.monotonic_time(:millisecond)
    result = fun.()
    duration = System.monotonic_time(:millisecond) - start
    {result, duration}
  end
end
```
