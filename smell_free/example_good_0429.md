```elixir
defmodule Scheduler.LeaseManager do
  @moduledoc """
  Provides distributed, lease-based task scheduling across a cluster.
  Before executing any scheduled job a node must acquire an exclusive
  database-backed lease for that job name. Leases have a TTL; stale leases
  from crashed nodes are automatically reclaimed on the next attempt.
  Only one node in the cluster will execute a given job within any TTL window,
  preventing duplicate runs without a centralised lock server.
  """

  alias Scheduler.{Lease, Repo}
  alias Ecto.Multi

  require Logger

  @type job_name :: binary()
  @type lease_opts :: [ttl_seconds: pos_integer()]

  @default_ttl_seconds 300

  @doc """
  Attempts to acquire the lease for `job_name` and, if successful, executes
  `fun`. The lease is released regardless of whether `fun` succeeds or raises.
  Returns `{:ok, result}`, `{:error, :lease_held}`, or `{:error, reason}`.
  """
  @spec with_lease(job_name(), (() -> term()), lease_opts()) ::
          {:ok, term()} | {:error, :lease_held | term()}
  def with_lease(job_name, fun, opts \\ [])
      when is_binary(job_name) and is_function(fun, 0) do
    ttl = Keyword.get(opts, :ttl_seconds, @default_ttl_seconds)
    node_id = to_string(Node.self())

    case acquire(job_name, node_id, ttl) do
      {:ok, lease} ->
        Logger.info("Lease acquired", job: job_name, node: node_id, ttl_seconds: ttl)
        execute_and_release(fun, lease)

      {:error, :lease_held} ->
        Logger.debug("Lease held by another node, skipping", job: job_name)
        {:error, :lease_held}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns the current lease holder for `job_name`, or `nil` when no active
  lease exists. Useful for admin dashboards and health checks.
  """
  @spec current_holder(job_name()) :: binary() | nil
  def current_holder(job_name) when is_binary(job_name) do
    now = DateTime.utc_now()

    case Repo.get_by(Lease, job_name: job_name) do
      %Lease{node_id: node, expires_at: exp} when exp > now -> node
      _ -> nil
    end
  end

  @doc """
  Forcibly releases a stuck lease. Intended for operator use only; normal
  code should rely on TTL expiry instead.
  """
  @spec force_release(job_name()) :: :ok | {:error, :not_found}
  def force_release(job_name) when is_binary(job_name) do
    case Repo.get_by(Lease, job_name: job_name) do
      nil ->
        {:error, :not_found}

      lease ->
        Repo.delete(lease)
        Logger.warning("Lease force-released", job: job_name)
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp acquire(job_name, node_id, ttl_seconds) do
    now = DateTime.utc_now()
    expires_at = DateTime.add(now, ttl_seconds, :second)

    Multi.new()
    |> Multi.run(:clear_stale, fn repo, _ ->
      {count, _} =
        repo.delete_all(
          from(l in Lease, where: l.job_name == ^job_name and l.expires_at < ^now)
        )
      {:ok, count}
    end)
    |> Multi.insert(:lease, %Lease{
      job_name: job_name,
      node_id: node_id,
      expires_at: expires_at
    })
    |> Repo.transaction()
    |> case do
      {:ok, %{lease: lease}} ->
        {:ok, lease}

      {:error, :lease, %Ecto.Changeset{errors: [job_name: _]}, _} ->
        {:error, :lease_held}

      {:error, _step, reason, _} ->
        {:error, reason}
    end
  end

  defp execute_and_release(fun, lease) do
    result = fun.()
    release(lease)
    {:ok, result}
  rescue
    e ->
      release(lease)
      reraise e, __STACKTRACE__
  end

  defp release(%Lease{} = lease) do
    case Repo.delete(lease) do
      {:ok, _} -> :ok
      {:error, reason} ->
        Logger.warning("Failed to release lease", job: lease.job_name, reason: inspect(reason))
    end
  end
end
```
