```elixir
defmodule Infrastructure.Deduplicator do
  @moduledoc """
  Prevents duplicate execution of idempotent write operations in distributed
  environments where the same request can arrive more than once due to client
  retries, load balancer replays, or network partition recovery. The first
  caller that presents a given `operation_key` executes the provided function;
  subsequent callers within the TTL window receive the cached result without
  re-executing the operation. All coordination is done through PostgreSQL to
  remain consistent across nodes without an additional dependency on Redis.
  """

  alias Infrastructure.{DeduplicationRecord, Repo}
  alias Ecto.Multi

  require Logger

  @type operation_key :: binary()
  @type dedup_opts :: [ttl_seconds: pos_integer()]
  @default_ttl_seconds 86_400

  @doc """
  Executes `fun` exactly once for `operation_key` within the TTL window.
  If `operation_key` has been seen before and the result is still cached,
  returns the cached `{:ok, result}` without calling `fun`. If `fun` raises
  or returns `{:error, reason}`, the attempt is NOT recorded, so a subsequent
  call may retry the operation.

  The return value of `fun` must be serialisable to JSON.
  """
  @spec once(operation_key(), (() -> {:ok, term()} | {:error, term()}), dedup_opts()) ::
          {:ok, term()} | {:error, term()}
  def once(operation_key, fun, opts \\ [])
      when is_binary(operation_key) and is_function(fun, 0) do
    ttl = Keyword.get(opts, :ttl_seconds, @default_ttl_seconds)

    case fetch_existing(operation_key) do
      {:ok, cached_result} ->
        Logger.debug("Deduplication cache hit", key: operation_key)
        {:ok, cached_result}

      :not_found ->
        execute_and_record(operation_key, fun, ttl)
    end
  end

  @doc """
  Checks whether `operation_key` has already been executed and its result
  is still cached. Does not execute the operation.
  """
  @spec already_executed?(operation_key()) :: boolean()
  def already_executed?(operation_key) when is_binary(operation_key) do
    match?({:ok, _}, fetch_existing(operation_key))
  end

  @doc """
  Purges all expired deduplication records. Run periodically via Oban
  or a scheduled task to prevent unbounded table growth.
  """
  @spec purge_expired() :: {:ok, non_neg_integer()}
  def purge_expired do
    now = DateTime.utc_now()
    {count, _} = Repo.delete_all(from(r in DeduplicationRecord, where: r.expires_at < ^now))
    Logger.info("Purged expired deduplication records", count: count)
    {:ok, count}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp fetch_existing(operation_key) do
    now = DateTime.utc_now()

    case Repo.get_by(DeduplicationRecord, operation_key: operation_key) do
      %DeduplicationRecord{result: result, expires_at: exp} when exp > now ->
        {:ok, result}

      _ ->
        :not_found
    end
  end

  defp execute_and_record(operation_key, fun, ttl) do
    case fun.() do
      {:ok, result} = ok ->
        record_result(operation_key, result, ttl)
        ok

      {:error, reason} = err ->
        Logger.debug("Deduplication: operation failed, not recording",
          key: operation_key,
          reason: inspect(reason)
        )
        err
    end
  end

  defp record_result(operation_key, result, ttl) do
    expires_at = DateTime.add(DateTime.utc_now(), ttl, :second)

    Multi.new()
    |> Multi.insert(:record,
      %DeduplicationRecord{}
      |> DeduplicationRecord.changeset(%{
        operation_key: operation_key,
        result: result,
        expires_at: expires_at
      }),
      on_conflict: :nothing,
      conflict_target: :operation_key
    )
    |> Repo.transaction()
    |> case do
      {:ok, _} -> :ok
      {:error, _step, reason, _} ->
        Logger.warning("Failed to persist deduplication record",
          key: operation_key,
          reason: inspect(reason)
        )
    end
  end
end
```
