```elixir
defmodule Platform.InstrumentedRepo do
  @moduledoc """
  A thin wrapper around an Ecto Repo that emits Telemetry events for
  every query, with contextual metadata such as query duration,
  operation type, and schema module.

  Mount this module in your supervision tree alongside the underlying Repo
  and replace direct `Repo.*` calls with `InstrumentedRepo.*` calls at the
  boundary layer.
  """

  alias Platform.Repo

  @event_prefix [:platform, :repo]

  @type result :: {:ok, term()} | {:error, term()}

  @doc "Instrumented wrapper for `Repo.get/3`."
  @spec get(module(), term(), keyword()) :: struct() | nil
  def get(schema, id, opts \\ []) do
    instrument(:get, schema, fn -> Repo.get(schema, id, opts) end)
  end

  @doc "Instrumented wrapper for `Repo.get_by/3`."
  @spec get_by(module(), keyword() | map(), keyword()) :: struct() | nil
  def get_by(schema, clauses, opts \\ []) do
    instrument(:get_by, schema, fn -> Repo.get_by(schema, clauses, opts) end)
  end

  @doc "Instrumented wrapper for `Repo.all/2`."
  @spec all(Ecto.Queryable.t(), keyword()) :: [struct()]
  def all(queryable, opts \\ []) do
    schema = extract_schema(queryable)
    instrument(:all, schema, fn -> Repo.all(queryable, opts) end)
  end

  @doc "Instrumented wrapper for `Repo.insert/2`."
  @spec insert(Ecto.Changeset.t() | struct(), keyword()) :: result()
  def insert(changeset_or_struct, opts \\ []) do
    schema = extract_schema(changeset_or_struct)
    instrument(:insert, schema, fn -> Repo.insert(changeset_or_struct, opts) end)
  end

  @doc "Instrumented wrapper for `Repo.update/2`."
  @spec update(Ecto.Changeset.t(), keyword()) :: result()
  def update(changeset, opts \\ []) do
    schema = extract_schema(changeset)
    instrument(:update, schema, fn -> Repo.update(changeset, opts) end)
  end

  @doc "Instrumented wrapper for `Repo.delete/2`."
  @spec delete(struct() | Ecto.Changeset.t(), keyword()) :: result()
  def delete(struct_or_changeset, opts \\ []) do
    schema = extract_schema(struct_or_changeset)
    instrument(:delete, schema, fn -> Repo.delete(struct_or_changeset, opts) end)
  end

  @doc "Instrumented wrapper for `Repo.transaction/2`."
  @spec transaction((-> term()), keyword()) :: {:ok, term()} | {:error, term()}
  def transaction(fun, opts \\ []) when is_function(fun) do
    instrument(:transaction, :transaction, fn -> Repo.transaction(fun, opts) end)
  end

  defp instrument(operation, schema, fun) do
    start_time = System.monotonic_time()
    metadata = %{operation: operation, schema: schema, repo: Repo}
    :telemetry.execute(@event_prefix ++ [:start], %{system_time: System.system_time()}, metadata)

    result = fun.()

    duration = System.monotonic_time() - start_time
    status = derive_status(result)

    :telemetry.execute(
      @event_prefix ++ [:stop],
      %{duration: duration},
      Map.merge(metadata, %{status: status})
    )

    result
  end

  defp derive_status({:ok, _}), do: :ok
  defp derive_status({:error, _}), do: :error
  defp derive_status(nil), do: :miss
  defp derive_status(_), do: :ok

  defp extract_schema(%Ecto.Changeset{data: %schema{}}), do: schema
  defp extract_schema(%schema{}), do: schema
  defp extract_schema(schema) when is_atom(schema), do: schema
  defp extract_schema(%Ecto.Query{from: %{source: {_, schema}}}) when is_atom(schema), do: schema
  defp extract_schema(_), do: :unknown
end
```
