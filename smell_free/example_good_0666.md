```elixir
defmodule MyApp.CRM.ContactMerger do
  @moduledoc """
  Merges duplicate contact records into a single canonical record.
  The merge strategy preserves the most complete data across both records,
  reassigns all related records (notes, activities, deals) to the winner,
  and marks the loser as merged with a reference to the winner.

  All writes happen inside a single database transaction. The caller
  chooses which contact is the canonical winner; the other is the loser.
  """

  alias Ecto.Multi
  alias MyApp.Repo
  alias MyApp.CRM.{Contact, Note, Activity, Deal}

  import Ecto.Query, warn: false

  @type merge_result :: %{
          winner: Contact.t(),
          loser_id: String.t(),
          reassigned: %{notes: non_neg_integer(), activities: non_neg_integer(), deals: non_neg_integer()}
        }

  @doc """
  Merges `loser` into `winner`. Returns `{:ok, merge_result}` or
  `{:error, step, reason, changes}`.
  """
  @spec merge(Contact.t(), Contact.t()) ::
          {:ok, merge_result()} | {:error, atom(), term(), map()}
  def merge(%Contact{} = winner, %Contact{} = loser) when winner.id != loser.id do
    Multi.new()
    |> Multi.run(:merge_fields, fn _repo, _ ->
      merge_contact_fields(winner, loser)
    end)
    |> Multi.run(:reassign_notes, fn _repo, _ ->
      {:ok, reassign(Note, loser.id, winner.id)}
    end)
    |> Multi.run(:reassign_activities, fn _repo, _ ->
      {:ok, reassign(Activity, loser.id, winner.id)}
    end)
    |> Multi.run(:reassign_deals, fn _repo, _ ->
      {:ok, reassign(Deal, loser.id, winner.id)}
    end)
    |> Multi.run(:mark_merged, fn _repo, %{merge_fields: updated_winner} ->
      mark_as_merged(loser, updated_winner.id)
      {:ok, updated_winner}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, changes} ->
        {:ok, %{
          winner: changes.merge_fields,
          loser_id: loser.id,
          reassigned: %{
            notes: changes.reassign_notes,
            activities: changes.reassign_activities,
            deals: changes.reassign_deals
          }
        }}

      {:error, step, reason, changes} ->
        {:error, step, reason, changes}
    end
  end

  @spec merge_contact_fields(Contact.t(), Contact.t()) ::
          {:ok, Contact.t()} | {:error, Ecto.Changeset.t()}
  defp merge_contact_fields(winner, loser) do
    merged_attrs = %{
      phone: winner.phone || loser.phone,
      company_name: winner.company_name || loser.company_name,
      job_title: winner.job_title || loser.job_title,
      linkedin_url: winner.linkedin_url || loser.linkedin_url,
      notes: merge_text(winner.notes, loser.notes)
    }

    winner
    |> Contact.changeset(merged_attrs)
    |> Repo.update()
  end

  @spec reassign(module(), String.t(), String.t()) :: non_neg_integer()
  defp reassign(schema, from_id, to_id) do
    {count, _} =
      schema
      |> where([r], r.contact_id == ^from_id)
      |> Repo.update_all(set: [contact_id: to_id])

    count
  end

  @spec mark_as_merged(Contact.t(), String.t()) :: :ok
  defp mark_as_merged(loser, winner_id) do
    loser
    |> Contact.merged_changeset(%{merged_into_id: winner_id, merged_at: DateTime.utc_now()})
    |> Repo.update!()

    :ok
  end

  @spec merge_text(String.t() | nil, String.t() | nil) :: String.t() | nil
  defp merge_text(nil, nil), do: nil
  defp merge_text(a, nil), do: a
  defp merge_text(nil, b), do: b
  defp merge_text(a, b) when a == b, do: a
  defp merge_text(a, b), do: "#{a}\n\n---\n\n#{b}"
end
```
