# Annotated Example – Large Messages

| Field | Value |
|---|---|
| **Smell name** | Large messages |
| **Expected smell location** | `Pipeline.StageCoordinator.hand_off/3` |
| **Affected function(s)** | `hand_off/3` |
| **Short explanation** | The pipeline coordinator collects the complete transformed dataset from one ETL stage and sends it as a single message to the next stage worker. Because the dataset can be very large (hundreds of thousands of wide rows), this inter-stage hand-off causes a large heap copy that blocks the coordinator process. |

```elixir
defmodule Pipeline.ColumnSchema do
  defstruct [:name, :type, :nullable, :description]

  @type t :: %__MODULE__{
          name: String.t(),
          type: :string | :integer | :float | :boolean | :datetime | :json,
          nullable: boolean(),
          description: String.t() | nil
        }
end

defmodule Pipeline.TransformationLog do
  defstruct [:rule_id, :rule_name, :field, :before, :after, :applied_at]

  @type t :: %__MODULE__{
          rule_id: String.t(),
          rule_name: String.t(),
          field: String.t(),
          before: term(),
          after: term(),
          applied_at: DateTime.t()
        }
end

defmodule Pipeline.Row do
  @enforce_keys [:id, :fields, :source]
  defstruct [:id, :fields, :source, :transformations, :quality_flags, :partition_key]

  @type t :: %__MODULE__{
          id: String.t(),
          fields: %{String.t() => term()},
          source: String.t(),
          transformations: [Pipeline.TransformationLog.t()],
          quality_flags: [String.t()],
          partition_key: String.t()
        }
end

defmodule Pipeline.Dataset do
  @enforce_keys [:id, :name, :schema, :rows]
  defstruct [:id, :name, :schema, :rows, :created_at, :source_system, :checksum]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          schema: [Pipeline.ColumnSchema.t()],
          rows: [Pipeline.Row.t()],
          created_at: DateTime.t(),
          source_system: String.t(),
          checksum: String.t()
        }
end

defmodule Pipeline.Transformer do
  @moduledoc "Applies transformation rules to a dataset."

  @spec transform(Pipeline.Dataset.t()) :: Pipeline.Dataset.t()
  def transform(%Pipeline.Dataset{rows: rows} = dataset) do
    now = DateTime.utc_now()

    transformed_rows =
      Enum.map(rows, fn row ->
        transformations =
          Enum.map(1..6, fn t ->
            field = "field_#{rem(String.length(row.id) * t, 20) + 1}"
            old_val = Map.get(row.fields, field)
            new_val = if is_number(old_val), do: old_val * 1.1, else: old_val

            %Pipeline.TransformationLog{
              rule_id: "rule_#{t}",
              rule_name: "normalise_#{field}",
              field: field,
              before: old_val,
              after: new_val,
              applied_at: now
            }
          end)

        %{row | transformations: transformations, quality_flags: ["validated", "normalised"]}
      end)

    %{dataset | rows: transformed_rows}
  end

  @spec build_dataset(String.t()) :: Pipeline.Dataset.t()
  def build_dataset(source) do
    now = DateTime.utc_now()

    schema =
      Enum.map(1..20, fn c ->
        %Pipeline.ColumnSchema{
          name: "field_#{c}",
          type: Enum.random([:string, :integer, :float, :boolean, :datetime]),
          nullable: rem(c, 4) == 0,
          description: "Column #{c} representing metric or attribute #{c}"
        }
      end)

    rows =
      Enum.map(1..100_000, fn n ->
        %Pipeline.Row{
          id: "row_#{n}",
          source: source,
          partition_key: "pk_#{rem(n, 1000)}",
          quality_flags: [],
          transformations: [],
          fields:
            Map.new(1..20, fn c ->
              val =
                case rem(c, 5) do
                  0 -> "string_val_#{rem(n * c, 10_000)}"
                  1 -> n * c
                  2 -> :rand.uniform() * 1000
                  3 -> rem(n, 2) == 0
                  _ -> DateTime.add(now, -n * 60, :second)
                end

              {"field_#{c}", val}
            end)
        }
      end)

    %Pipeline.Dataset{
      id: "ds_#{source}_#{:rand.uniform(999_999)}",
      name: "Transformed Dataset – #{source}",
      schema: schema,
      rows: rows,
      created_at: now,
      source_system: source,
      checksum: Base.encode16(:crypto.hash(:sha256, source))
    }
  end
end

defmodule Pipeline.LoaderWorker do
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, nil, opts)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_info({:load_dataset, pipeline_id, dataset}, _state) do
    {:noreply, {pipeline_id, dataset.id, length(dataset.rows)}}
  end
end

defmodule Pipeline.StageCoordinator do
  @moduledoc """
  Coordinates ETL stage transitions. Applies transformations to the source
  dataset and hands the result off to the next pipeline stage worker.
  """

  require Logger

  @spec hand_off(pid(), String.t(), String.t()) :: :ok
  def hand_off(next_stage_pid, pipeline_id, source_system) do
    Logger.info("Building and transforming dataset for pipeline #{pipeline_id}...")

    dataset =
      source_system
      |> Pipeline.Transformer.build_dataset()
      |> Pipeline.Transformer.transform()

    Logger.info(
      "Dataset #{dataset.id} ready: #{length(dataset.rows)} rows. Handing off to next stage..."
    )

    # VALIDATION: SMELL START - Large messages
    # VALIDATION: This is a smell because `dataset` contains 100,000 Row structs,
    # each with a 20-key fields map, 6 TransformationLog entries, and quality
    # flags. Additionally, the Dataset struct itself holds a 20-element schema
    # list. Sending this entire structure as one process message forces the
    # BEAM to deep-copy everything across heaps, blocking the coordinator for
    # an extended period and creating a large GC burden on the loader worker.
    send(next_stage_pid, {:load_dataset, pipeline_id, dataset})
    # VALIDATION: SMELL END

    Logger.info("Hand-off complete for pipeline #{pipeline_id}.")
    :ok
  end
end
```
