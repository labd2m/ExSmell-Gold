```elixir
defmodule Replication.RegionSync do
  @moduledoc """
  Coordinates eventual consistency replication of critical domain records
  to secondary regions. Each replication event is inserted as an Oban job
  scoped to the target region's queue so failures in one region do not block
  others. The syncer resolves conflicts using a last-write-wins strategy
  based on the `updated_at` timestamp, which is sufficient for the mutable
  configuration data this module handles.
  """

  use Oban.Worker,
    queue: :replication,
    max_attempts: 10,
    unique: [period: 60, fields: [:args]]

  alias Replication.{RegionClient, RegionRegistry}

  require Logger

  @type region :: binary()
  @type entity_type :: binary()

  # ---------------------------------------------------------------------------
  # Public API (called by domain contexts)
  # ---------------------------------------------------------------------------

  @doc """
  Enqueues replication jobs for `entity` to all configured secondary regions.
  Returns a list of inserted Oban job results.
  """
  @spec replicate(struct(), entity_type()) :: [{:ok, Oban.Job.t()} | {:error, term()}]
  def replicate(entity, entity_type) when is_binary(entity_type) do
    target_regions = RegionRegistry.secondary_regions()

    Enum.map(target_regions, fn region ->
      args = %{
        "entity_type" => entity_type,
        "entity_id" => entity.id,
        "region" => region,
        "payload" => serialise(entity),
        "source_updated_at" => DateTime.to_iso8601(entity.updated_at)
      }

      args
      |> new(queue: :"replication_#{region}")
      |> Oban.insert()
    end)
  end

  @doc """
  Marks an entity for deletion in all secondary regions.
  """
  @spec replicate_deletion(binary(), entity_type()) :: [{:ok, Oban.Job.t()} | {:error, term()}]
  def replicate_deletion(entity_id, entity_type)
      when is_binary(entity_id) and is_binary(entity_type) do
    target_regions = RegionRegistry.secondary_regions()

    Enum.map(target_regions, fn region ->
      args = %{
        "operation" => "delete",
        "entity_type" => entity_type,
        "entity_id" => entity_id,
        "region" => region
      }

      args
      |> new(queue: :"replication_#{region}")
      |> Oban.insert()
    end)
  end

  # ---------------------------------------------------------------------------
  # Oban worker
  # ---------------------------------------------------------------------------

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"operation" => "delete"} = args}) do
    %{"entity_type" => type, "entity_id" => id, "region" => region} = args

    case RegionClient.delete(region, type, id) do
      :ok ->
        Logger.info("Deletion replicated", region: region, type: type, id: id)
        :ok

      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  def perform(%Oban.Job{args: args}) do
    %{
      "entity_type" => type,
      "entity_id" => id,
      "region" => region,
      "payload" => payload,
      "source_updated_at" => source_ts
    } = args

    with {:ok, source_updated_at} <- DateTime.from_iso8601(source_ts),
         :ok <- check_conflict(region, type, id, source_updated_at),
         :ok <- RegionClient.upsert(region, type, id, payload) do
      Logger.info("Entity replicated",
        region: region,
        type: type,
        id: id
      )

      :ok
    else
      {:error, :stale_write} ->
        Logger.debug("Skipping stale replication write",
          region: region,
          type: type,
          id: id
        )

        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp check_conflict(region, type, id, source_updated_at) do
    case RegionClient.get_updated_at(region, type, id) do
      {:ok, remote_updated_at} ->
        if DateTime.compare(source_updated_at, remote_updated_at) == :gt do
          :ok
        else
          {:error, :stale_write}
        end

      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp serialise(entity) do
    entity
    |> Map.from_struct()
    |> Map.drop([:__meta__])
    |> Jason.encode!()
  end
end
```
