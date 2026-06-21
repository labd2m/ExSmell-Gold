# File: `example_good_90.md`

```elixir
defmodule Multitenancy.RepoRouter do
  @moduledoc """
  Wraps Ecto repository operations with automatic tenant schema prefixing,
  eliminating the need for callers to supply the prefix on every query.

  The active tenant is stored in the calling process dictionary for the
  duration of a request. All repo operations delegated through this module
  respect the active tenant automatically.
  """

  alias Multitenancy.TenantRegistry

  @repo MyApp.Repo
  @tenant_key {__MODULE__, :tenant_prefix}

  @type prefix :: String.t()
  @type tenant_id :: String.t()

  @doc """
  Sets the active tenant for the current process.

  All subsequent `RepoRouter` calls in this process will use the tenant's
  schema prefix until `clear_tenant/0` is called or the process exits.

  Returns `{:error, :unknown_tenant}` if the tenant is not registered.
  """
  @spec set_tenant(tenant_id()) :: :ok | {:error, :unknown_tenant}
  def set_tenant(tenant_id) when is_binary(tenant_id) do
    case TenantRegistry.fetch_prefix(tenant_id) do
      {:ok, prefix} ->
        Process.put(@tenant_key, prefix)
        :ok

      {:error, :not_found} ->
        {:error, :unknown_tenant}
    end
  end

  @doc """
  Removes the active tenant association from the current process.
  """
  @spec clear_tenant() :: :ok
  def clear_tenant do
    Process.delete(@tenant_key)
    :ok
  end

  @doc """
  Returns the currently active tenant prefix for this process.

  Returns `{:ok, prefix}` or `{:error, :no_tenant_set}`.
  """
  @spec current_prefix() :: {:ok, prefix()} | {:error, :no_tenant_set}
  def current_prefix do
    case Process.get(@tenant_key) do
      nil -> {:error, :no_tenant_set}
      prefix -> {:ok, prefix}
    end
  end

  @doc """
  Executes `fun/1` within the context of the given tenant, restoring
  the previous tenant context afterwards.

  `fun/1` receives the active prefix as its argument. This is safe to
  nest for cross-tenant operations.
  """
  @spec with_tenant(tenant_id(), (prefix() -> result)) :: result | {:error, :unknown_tenant}
        when result: any()
  def with_tenant(tenant_id, fun) when is_binary(tenant_id) and is_function(fun, 1) do
    previous = Process.get(@tenant_key)

    case set_tenant(tenant_id) do
      :ok ->
        try do
          {:ok, prefix} = current_prefix()
          fun.(prefix)
        after
          restore_previous_tenant(previous)
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Equivalent to `Repo.all/2` with the active tenant prefix applied.
  """
  @spec all(Ecto.Queryable.t(), keyword()) :: [Ecto.Schema.t()]
  def all(queryable, opts \\ []) do
    @repo.all(queryable, opts |> Keyword.merge(prefix_opt()))
  end

  @doc """
  Equivalent to `Repo.get/3` with the active tenant prefix applied.
  """
  @spec get(Ecto.Queryable.t(), term(), keyword()) :: Ecto.Schema.t() | nil
  def get(queryable, id, opts \\ []) do
    @repo.get(queryable, id, opts |> Keyword.merge(prefix_opt()))
  end

  @doc """
  Equivalent to `Repo.insert/2` with the active tenant prefix applied.
  """
  @spec insert(Ecto.Changeset.t(), keyword()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  def insert(changeset, opts \\ []) do
    @repo.insert(changeset, opts |> Keyword.merge(prefix_opt()))
  end

  @doc """
  Equivalent to `Repo.update/2` with the active tenant prefix applied.
  """
  @spec update(Ecto.Changeset.t(), keyword()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  def update(changeset, opts \\ []) do
    @repo.update(changeset, opts |> Keyword.merge(prefix_opt()))
  end

  @doc """
  Equivalent to `Repo.delete/2` with the active tenant prefix applied.
  """
  @spec delete(Ecto.Schema.t(), keyword()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  def delete(struct, opts \\ []) do
    @repo.delete(struct, opts |> Keyword.merge(prefix_opt()))
  end

  defp prefix_opt do
    case Process.get(@tenant_key) do
      nil -> []
      prefix -> [prefix: prefix]
    end
  end

  defp restore_previous_tenant(nil), do: Process.delete(@tenant_key)
  defp restore_previous_tenant(prefix), do: Process.put(@tenant_key, prefix)
end
```
