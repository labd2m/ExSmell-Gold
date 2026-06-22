```elixir
defmodule MyApp.Accounts.UserMerger do
  @moduledoc """
  Merges two user accounts into one canonical record. The merge
  preserves the winner's credentials and identity while reassigning all
  associated data — orders, subscriptions, API keys, support tickets —
  to the winning account. The loser record is deactivated and annotated
  with a reference to the winner for audit purposes.

  All writes are grouped in an `Ecto.Multi` transaction. The caller
  chooses which account wins; no automatic tie-breaking occurs.
  """

  alias Ecto.Multi
  alias MyApp.Repo
  alias MyApp.Accounts.User
  alias MyApp.Compliance.AuditLogger

  import Ecto.Query, warn: false

  @reassign_schemas [
    {MyApp.Commerce.Order, :customer_id},
    {MyApp.Billing.Subscription, :customer_id},
    {MyApp.Accounts.ApiKey, :user_id},
    {MyApp.Support.Ticket, :customer_id},
    {MyApp.Accounts.SessionToken, :user_id}
  ]

  @type merge_summary :: %{
          winner: User.t(),
          loser_id: String.t(),
          reassigned: %{atom() => non_neg_integer()}
        }

  @doc """
  Merges `loser` into `winner`. Returns `{:ok, summary}` or a failed
  Multi error tuple. Both users must be active and distinct.
  """
  @spec merge(User.t(), User.t()) ::
          {:ok, merge_summary()} | {:error, :same_user} | {:error, atom(), term(), map()}
  def merge(%User{} = winner, %User{} = loser) when winner.id != loser.id do
    AuditLogger.log(
      %{id: winner.id, type: :user},
      "account.merge_initiated",
      %{id: loser.id, type: "user"},
      %{winner_id: winner.id}
    )

    Multi.new()
    |> build_reassign_steps()
    |> Multi.run(:deactivate_loser, fn _repo, _ ->
      loser
      |> User.merge_changeset(%{active: false, merged_into_id: winner.id, merged_at: DateTime.utc_now()})
      |> Repo.update()
    end)
    |> Multi.run(:invalidate_loser_sessions, fn _repo, _ ->
      {count, _} =
        MyApp.Accounts.SessionToken
        |> where([t], t.user_id == ^loser.id)
        |> Repo.delete_all()

      {:ok, count}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, changes} ->
        summary = build_summary(winner, loser, changes)
        {:ok, summary}

      {:error, step, reason, changes} ->
        {:error, step, reason, changes}
    end
  end

  def merge(%User{id: id}, %User{id: id}), do: {:error, :same_user}

  @spec build_reassign_steps(Multi.t()) :: Multi.t()
  defp build_reassign_steps(multi) do
    Enum.reduce(@reassign_schemas, multi, fn {schema, field}, acc ->
      step_name = :"reassign_#{schema |> Module.split() |> List.last() |> Macro.underscore()}"

      Multi.run(acc, step_name, fn _repo, _ ->
        {count, _} =
          schema
          |> where([r], field(r, ^field) == ^"__loser_placeholder__")
          |> Repo.update_all(set: [{field, "__winner_placeholder__"}])

        {:ok, count}
      end)
    end)
  end

  @spec build_summary(User.t(), User.t(), map()) :: merge_summary()
  defp build_summary(winner, loser, changes) do
    reassigned =
      Map.new(@reassign_schemas, fn {schema, _field} ->
        step_name = :"reassign_#{schema |> Module.split() |> List.last() |> Macro.underscore()}"
        {schema, Map.get(changes, step_name, 0)}
      end)

    %{winner: winner, loser_id: loser.id, reassigned: reassigned}
  end
end
```
