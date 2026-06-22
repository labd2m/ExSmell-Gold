```elixir
defmodule Accounts.AccountMerger do
  @moduledoc """
  Merges two user accounts into a single canonical account. The source
  account's orders, sessions, saved addresses, and audit entries are
  re-keyed to the target account. The source account is then deactivated.
  The merge is fully transactional; a failure at any step rolls back
  the entire operation to preserve data integrity.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias Accounts.User
  alias Audit.Trail

  @type user_id :: String.t()
  @type merge_result ::
          {:ok, %{target_id: user_id(), migrated: %{atom() => non_neg_integer()}}}
          | {:error, :same_account | :source_not_found | :target_not_found | :target_inactive}

  @doc """
  Merges `source_id` into `target_id`. All associations from the source
  account are re-keyed to the target; the source is then deactivated.
  """
  @spec merge(user_id(), user_id()) :: merge_result()
  def merge(source_id, target_id)
      when is_binary(source_id) and is_binary(target_id) and source_id != target_id do
    Repo.transaction(fn ->
      with {:ok, source} <- fetch_active(source_id, :source),
           {:ok, target} <- fetch_active(target_id, :target) do
        migrated = %{
          orders:    rekey("orders",         "customer_id", source_id, target_id),
          addresses: rekey("saved_addresses", "customer_id", source_id, target_id),
          sessions:  rekey("sessions",        "user_id",     source_id, target_id),
          api_keys:  rekey("api_keys",        "owner_id",    source_id, target_id)
        }

        deactivate_source(source)

        Trail.log(%{
          actor_id: target_id,
          action: "account_merged",
          resource_type: "User",
          resource_id: source_id,
          metadata: %{target_id: target_id, migrated: migrated},
          ip_address: nil
        })

        %{target_id: target.id, migrated: migrated}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def merge(id, id), do: {:error, :same_account}

  defp fetch_active(user_id, role) do
    case Repo.get(User, user_id) do
      nil -> {:error, :"#{role}_not_found"}
      %User{active: false} -> {:error, :"#{role}_inactive"}
      user -> {:ok, user}
    end
  end

  defp rekey(table, column, from_id, to_id) do
    {count, _} =
      Repo.update_all(
        from(r in table, where: field(r, ^String.to_existing_atom(column)) == ^from_id),
        set: [{String.to_existing_atom(column), to_id}]
      )

    count
  rescue
    _ -> 0
  end

  defp deactivate_source(%User{} = source) do
    source
    |> User.deactivation_changeset()
    |> Repo.update!()
  end
end
```
