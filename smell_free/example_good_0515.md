```elixir
defmodule MyApp.DataWarehouse.SnapshotExporter do
  @moduledoc """
  Exports point-in-time snapshots of core domain entities to the data
  warehouse by writing Parquet-compatible NDJSON files to object storage.
  Each entity type has a dedicated export function; all share the same
  batched streaming architecture to handle arbitrarily large tables.

  Exports are recorded in the `snapshot_exports` table so that downstream
  ETL pipelines can detect new files by querying the log rather than
  polling the object store.
  """

  require Logger

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias MyApp.DataWarehouse.{SnapshotExport, ExportSerializer}
  alias MyApp.Storage

  @batch_size 1_000
  @supported_entities [:users, :orders, :products, :subscriptions]

  @type entity :: :users | :orders | :products | :subscriptions
  @type export_result :: %{
          entity: entity(),
          object_key: String.t(),
          row_count: non_neg_integer(),
          exported_at: DateTime.t()
        }

  @doc """
  Exports a snapshot of `entity` to object storage. Returns
  `{:ok, result}` or `{:error, reason}`.
  """
  @spec export(entity()) :: {:ok, export_result()} | {:error, term()}
  def export(entity) when entity in @supported_entities do
    exported_at = DateTime.utc_now()
    object_key = build_key(entity, exported_at)

    Logger.info("snapshot_export_started", entity: entity, key: object_key)

    with {:ok, {content, row_count}} <- stream_entity(entity),
         {:ok, _url} <- Storage.put(object_key, content, content_type: "application/x-ndjson"),
         {:ok, _record} <- record_export(entity, object_key, row_count, exported_at) do
      Logger.info("snapshot_export_finished", entity: entity, rows: row_count, key: object_key)
      {:ok, %{entity: entity, object_key: object_key, row_count: row_count, exported_at: exported_at}}
    end
  end

  @spec stream_entity(entity()) :: {:ok, {binary(), non_neg_integer()}} | {:error, term()}
  defp stream_entity(entity) do
    {module, selector} = entity_config(entity)

    result =
      Repo.transaction(fn ->
        module
        |> selector.()
        |> Repo.stream(max_rows: @batch_size)
        |> Enum.reduce({[], 0}, fn record, {lines, count} ->
          json = record |> ExportSerializer.to_row(entity) |> Jason.encode!()
          {[json | lines], count + 1}
        end)
      end)

    case result do
      {:ok, {lines, count}} ->
        content = lines |> Enum.reverse() |> Enum.join("\n")
        {:ok, {content, count}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec build_key(entity(), DateTime.t()) :: String.t()
  defp build_key(entity, dt) do
    date = dt |> DateTime.to_date() |> Date.to_iso8601()
    ts = DateTime.to_unix(dt)
    "snapshots/#{entity}/#{date}/#{ts}.ndjson"
  end

  @spec record_export(entity(), String.t(), non_neg_integer(), DateTime.t()) ::
          {:ok, SnapshotExport.t()} | {:error, Ecto.Changeset.t()}
  defp record_export(entity, object_key, row_count, exported_at) do
    %SnapshotExport{}
    |> SnapshotExport.changeset(%{
      entity: entity,
      object_key: object_key,
      row_count: row_count,
      exported_at: exported_at
    })
    |> Repo.insert()
  end

  @spec entity_config(entity()) :: {module(), (module() -> Ecto.Query.t())}
  defp entity_config(:users), do: {MyApp.Accounts.User, &from(&1, where: [active: true])}
  defp entity_config(:orders), do: {MyApp.Commerce.Order, &from(&1, [])}
  defp entity_config(:products), do: {MyApp.Catalog.Product, &from(&1, where: [active: true])}
  defp entity_config(:subscriptions), do: {MyApp.Billing.Subscription, &from(&1, [])}
end
```
