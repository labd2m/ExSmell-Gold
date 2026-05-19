```elixir
defmodule Pipeline.StageConfig do
  defstruct [
    :stage_id,
    :name,
    :type,
    :parameters,
    :retry_policy,
    :timeout_ms,
    :output_schema
  ]
end

defmodule Pipeline.DataRecord do
  @enforce_keys [:id, :source, :payload]
  defstruct [
    :id,
    :source,
    :payload,
    :schema_version,
    :ingested_at,
    :tags,
    :lineage,
    :quality_scores
  ]
end

defmodule Pipeline.DataSource do
  @moduledoc "Simulates reading raw records from an ingestion pipeline."

  @spec read_batch(String.t(), non_neg_integer()) :: list(Pipeline.DataRecord.t())
  def read_batch(source_id, limit) do
    Enum.map(1..limit, fn i ->
      %Pipeline.DataRecord{
        id: "REC-#{source_id}-#{i}",
        source: source_id,
        payload: %{
          field_a: "value_a_#{i}",
          field_b: rem(i, 1_000),
          field_c: Enum.map(1..20, &"item_#{&1}_rec_#{i}"),
          field_d: %{nested_x: i * 2, nested_y: "y_#{i}", nested_z: rem(i, 100)},
          field_e: :crypto.strong_rand_bytes(32) |> Base.encode64()
        },
        schema_version: "v2.4",
        ingested_at: DateTime.utc_now(),
        tags: ["source:#{source_id}", "batch:#{div(i, 500)}"],
        lineage: %{
          upstream_job: "ingest-job-#{rem(i, 10)}",
          partition: rem(i, 12),
          offset: i * 1_000
        },
        quality_scores: %{
          completeness: Float.round(:rand.uniform(), 4),
          accuracy: Float.round(:rand.uniform(), 4),
          timeliness: Float.round(:rand.uniform(), 4)
        }
      }
    end)
  end
end

defmodule Pipeline.StageWorker do
  @moduledoc "Processes a batch of records for a given pipeline stage."

  def run(%Pipeline.StageConfig{} = config) do
    receive do
      {:data, records} ->
        transformed =
          Enum.map(records, fn rec ->
            Map.put(rec, :tags, ["stage:#{config.stage_id}" | rec.tags])
          end)

        {:ok, length(transformed)}
    after
      config.timeout_ms ->
        {:error, :timeout}
    end
  end
end

defmodule Pipeline.DataLoader do
  @moduledoc "Loads data and fans it out to stage worker tasks."

  require Logger

  @spec stream_to_worker(Pipeline.StageConfig.t(), list(Pipeline.DataRecord.t())) ::
          Task.t()
  def stream_to_worker(%Pipeline.StageConfig{} = config, records) do
    parent = self()

    task =
      Task.async(fn ->
        send(parent, {:worker_ready, self()})

        receive do
          {:data, _} = msg ->
            Pipeline.StageWorker.run(config)
            msg
        end
      end)

    receive do
      {:worker_ready, worker_pid} ->
        Logger.info("Worker #{inspect(worker_pid)} ready — sending #{length(records)} records")
        send(task.pid, {:data, records})
    after
      5_000 -> raise "Worker did not become ready in time"
    end

    task
  end

  @spec execute(list(Pipeline.StageConfig.t())) :: list(Task.t())
  def execute(stages) do
    records = Pipeline.DataSource.read_batch("source-primary", 12_000)

    Enum.map(stages, fn stage ->
      stream_to_worker(stage, records)
    end)
  end
end
```
