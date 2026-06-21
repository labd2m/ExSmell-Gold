# File: `example_good_428.md`

```elixir
defmodule Accounts.MergeRequest do
  @moduledoc """
  Manages the workflow for merging two user accounts into one canonical account.

  A merge moves all owned resources from the source account to the target,
  then deactivates the source. The process is transactional: either all
  resource transfers succeed or none are committed.

  Resource transfer strategies are registered per resource type so this
  module stays decoupled from specific domain schemas.
  """

  import Ecto.Query, warn: false

  alias Accounts.{Repo, User}

  @type user_id :: Ecto.UUID.t()
  @type resource_type :: atom()
  @type transfer_fn :: (user_id(), user_id() -> :ok | {:error, term()})

  @type merge_result :: %{
          target_id: user_id(),
          source_id: user_id(),
          transferred: [resource_type()],
          failed: [{resource_type(), term()}]
        }

  @registered_transfers Application.compile_env(:my_app, [:account_merge, :transfers], [])

  @doc """
  Merges `source` account into `target`, transferring all registered
  resource types within a single database transaction.

  The source account is deactivated upon successful completion.
  Returns `{:ok, merge_result}` or `{:error, reason}`.
  """
  @spec merge(User.t(), User.t()) :: {:ok, merge_result()} | {:error, atom()}
  def merge(%User{} = target, %User{} = source) do
    with :ok <- validate_merge(target, source) do
      execute_merge(target, source)
    end
  end

  @doc """
  Registers a transfer function for a resource type at runtime.

  The function receives `{source_user_id, target_user_id}` and must
  return `:ok` or `{:error, reason}`.
  """
  @spec register_transfer(resource_type(), transfer_fn()) :: :ok
  def register_transfer(resource_type, transfer_fn)
      when is_atom(resource_type) and is_function(transfer_fn, 2) do
    Application.put_env(:my_app, :account_merge_transfers,
      [{resource_type, transfer_fn} | current_transfers()])

    :ok
  end

  @doc """
  Returns a preview of what would be transferred without executing the merge.
  """
  @spec preview(User.t(), User.t()) :: {:ok, [resource_type()]} | {:error, atom()}
  def preview(%User{} = target, %User{} = source) do
    case validate_merge(target, source) do
      :ok -> {:ok, Enum.map(current_transfers(), &elem(&1, 0))}
      error -> error
    end
  end

  defp validate_merge(%User{id: tid}, %User{id: sid}) do
    cond do
      tid == sid -> {:error, :cannot_merge_same_account}
      not active_user?(tid) -> {:error, :target_not_active}
      not active_user?(sid) -> {:error, :source_not_active}
      true -> :ok
    end
  end

  defp execute_merge(target, source) do
    Repo.transaction(fn ->
      {transferred, failed} = run_transfers(target.id, source.id)

      if failed != [] do
        Repo.rollback({:transfer_failures, failed})
      end

      deactivate_source(source)

      %{
        target_id: target.id,
        source_id: source.id,
        transferred: transferred,
        failed: failed
      }
    end)
    |> case do
      {:ok, result} -> {:ok, result}
      {:error, {:transfer_failures, failed}} -> {:error, {:transfer_failed, failed}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_transfers(target_id, source_id) do
    current_transfers()
    |> Enum.reduce({[], []}, fn {resource_type, transfer_fn}, {ok_acc, err_acc} ->
      case transfer_fn.(source_id, target_id) do
        :ok -> {[resource_type | ok_acc], err_acc}
        {:error, reason} -> {ok_acc, [{resource_type, reason} | err_acc]}
      end
    end)
    |> then(fn {ok, err} -> {Enum.reverse(ok), Enum.reverse(err)} end)
  end

  defp deactivate_source(source) do
    source
    |> User.deactivation_changeset(%{deactivated_at: DateTime.utc_now(), merge_target: true})
    |> Repo.update!()
  end

  defp active_user?(user_id) do
    User
    |> where([u], u.id == ^user_id and is_nil(u.deactivated_at))
    |> Repo.exists?()
  end

  defp current_transfers do
    Application.get_env(:my_app, :account_merge_transfers, @registered_transfers)
  end
end
```
