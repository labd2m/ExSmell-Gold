```elixir
defmodule MyApp.Payments.IdempotencyGuard do
  @moduledoc """
  Enforces idempotency for payment API operations by associating each
  caller-provided idempotency key with the outcome of the first
  successful request. Subsequent requests with the same key within the
  validity window replay the cached outcome without re-executing the
  operation, preventing duplicate charges from retried HTTP requests.

  Keys and their outcomes are persisted in the `idempotency_records`
  table rather than held only in memory, so the guarantee survives node
  restarts.
  """

  alias MyApp.Repo
  alias MyApp.Payments.IdempotencyRecord

  import Ecto.Query, warn: false

  @key_ttl_hours 24

  @type idempotency_key :: String.t()
  @type operation_name :: String.t()
  @type outcome :: map()

  @doc """
  Checks `key` for a cached outcome and either returns it or calls
  `fun/0`. If `fun/0` succeeds the outcome is persisted and returned.
  If `fun/0` fails the key is not recorded so the caller can retry.

  Returns `{:ok, outcome, :cached}` when replaying a prior result, or
  `{:ok, outcome, :executed}` when `fun` ran successfully.
  """
  @spec with_idempotency(idempotency_key(), operation_name(), (-> {:ok, outcome()} | {:error, term()})) ::
          {:ok, outcome(), :cached | :executed}
          | {:error, :key_conflict}
          | {:error, term()}
  def with_idempotency(key, operation, fun)
      when is_binary(key) and is_binary(operation) and is_function(fun, 0) do
    case lookup(key, operation) do
      {:ok, :cached, outcome} ->
        {:ok, outcome, :cached}

      {:ok, :conflict} ->
        {:error, :key_conflict}

      :miss ->
        run_and_record(key, operation, fun)
    end
  end

  @doc "Returns all idempotency records for `operation` created in the last 24 hours."
  @spec recent_records(operation_name()) :: [IdempotencyRecord.t()]
  def recent_records(operation) when is_binary(operation) do
    cutoff = DateTime.add(DateTime.utc_now(), -@key_ttl_hours, :hour)

    IdempotencyRecord
    |> where([r], r.operation == ^operation and r.inserted_at >= ^cutoff)
    |> order_by([r], desc: r.inserted_at)
    |> Repo.all()
  end

  @spec lookup(idempotency_key(), operation_name()) ::
          {:ok, :cached, outcome()} | {:ok, :conflict} | :miss
  defp lookup(key, operation) do
    cutoff = DateTime.add(DateTime.utc_now(), -@key_ttl_hours, :hour)

    case Repo.get_by(IdempotencyRecord, idempotency_key: key) do
      nil ->
        :miss

      %IdempotencyRecord{} = record when record.inserted_at < cutoff ->
        Repo.delete(record)
        :miss

      %IdempotencyRecord{operation: ^operation, outcome: outcome} ->
        {:ok, :cached, outcome}

      %IdempotencyRecord{} ->
        {:ok, :conflict}
    end
  end

  @spec run_and_record(idempotency_key(), operation_name(), (-> {:ok, outcome()} | {:error, term()})) ::
          {:ok, outcome(), :executed} | {:error, term()}
  defp run_and_record(key, operation, fun) do
    case fun.() do
      {:ok, outcome} ->
        persist(key, operation, outcome)
        {:ok, outcome, :executed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec persist(idempotency_key(), operation_name(), outcome()) :: :ok
  defp persist(key, operation, outcome) do
    %IdempotencyRecord{}
    |> IdempotencyRecord.changeset(%{
      idempotency_key: key,
      operation: operation,
      outcome: outcome
    })
    |> Repo.insert(on_conflict: :nothing)

    :ok
  end
end
```
