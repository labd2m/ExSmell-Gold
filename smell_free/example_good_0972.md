```elixir
defmodule MyApp.Infra.DeadLetterReviewer do
  @moduledoc """
  An admin utility that queries dead-letter records across multiple
  sources, provides filtering and summary statistics, and supports
  bulk retry or discard operations. Sources are pluggable adapters that
  implement the `DeadLetterSource` behaviour; new sources are added by
  registering them in `@sources`.
  """

  alias MyApp.Repo

  import Ecto.Query, warn: false

  @sources [
    MyApp.Streaming.Sources.KafkaDLQ,
    MyApp.Devices.Sources.DeviceCommandDLQ,
    MyApp.Webhooks.Sources.WebhookDLQ
  ]

  @type source_name :: String.t()
  @type dead_letter :: %{
          id: String.t(),
          source: source_name(),
          raw: term(),
          reason: String.t(),
          arrived_at: DateTime.t(),
          retry_count: non_neg_integer()
        }

  @type summary :: %{
          source: source_name(),
          total: non_neg_integer(),
          oldest_at: DateTime.t() | nil
        }

  @doc "Returns dead-letter records from all sources matching `filters`."
  @spec list(keyword()) :: [dead_letter()]
  def list(filters \\ []) do
    @sources
    |> Task.async_stream(
      fn source ->
        source.list(filters)
      end,
      timeout: 10_000,
      on_timeout: :kill_task,
      ordered: false
    )
    |> Enum.flat_map(fn
      {:ok, records} -> records
      _ -> []
    end)
    |> Enum.sort_by(& &1.arrived_at, {:desc, DateTime})
  end

  @doc "Returns per-source summary statistics."
  @spec summary() :: [summary()]
  def summary do
    @sources
    |> Task.async_stream(
      fn source -> source.summary() end,
      timeout: 5_000,
      on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, s} -> [s]
      _ -> []
    end)
  end

  @doc """
  Retries all records with `ids` from `source_name`. Returns a map of
  id to `:ok` or `{:error, reason}`.
  """
  @spec retry_many(source_name(), [String.t()]) :: %{String.t() => :ok | {:error, term()}}
  def retry_many(source_name, ids) when is_binary(source_name) and is_list(ids) do
    case find_source(source_name) do
      nil ->
        Map.new(ids, fn id -> {id, {:error, :unknown_source}} end)

      source ->
        Map.new(ids, fn id ->
          result = source.retry(id)
          {id, result}
        end)
    end
  end

  @doc "Discards all records with `ids` from `source_name`."
  @spec discard_many(source_name(), [String.t()]) :: %{String.t() => :ok | {:error, term()}}
  def discard_many(source_name, ids) when is_binary(source_name) and is_list(ids) do
    case find_source(source_name) do
      nil ->
        Map.new(ids, fn id -> {id, {:error, :unknown_source}} end)

      source ->
        Map.new(ids, fn id ->
          result = source.discard(id)
          {id, result}
        end)
    end
  end

  @doc "Returns all registered source names."
  @spec source_names() :: [source_name()]
  def source_names do
    Enum.map(@sources, & &1.source_name())
  end

  @spec find_source(source_name()) :: module() | nil
  defp find_source(name) do
    Enum.find(@sources, fn s -> s.source_name() == name end)
  end
end

defmodule MyApp.Infra.DeadLetterSource do
  @moduledoc "Behaviour contract for dead-letter source adapter modules."

  @callback source_name() :: String.t()
  @callback list(keyword()) :: [MyApp.Infra.DeadLetterReviewer.dead_letter()]
  @callback summary() :: MyApp.Infra.DeadLetterReviewer.summary()
  @callback retry(String.t()) :: :ok | {:error, term()}
  @callback discard(String.t()) :: :ok | {:error, term()}
end
```
