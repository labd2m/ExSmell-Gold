```elixir
defmodule Crm.Contacts.MergeCoordinator do
  @moduledoc """
  Coordinates the merging of duplicate contact records in the CRM.

  Merges a set of duplicate contacts into a single canonical record,
  transferring associated activities, tags, and custom fields while
  preserving the full audit history.
  """

  alias Crm.Contacts.{Contact, Activity, Tag, CustomField, MergeRecord}
  alias Crm.Repo
  import Ecto.Query, warn: false

  @type merge_result ::
          {:ok, Contact.t()}
          | {:error, :insufficient_contacts}
          | {:error, :canonical_not_in_set}
          | {:error, Ecto.Changeset.t()}

  @doc """
  Merges duplicate contacts into the designated canonical contact.

  All activities, tags, and custom fields from duplicates are re-associated
  to the canonical contact. Duplicate records are then soft-deleted.
  """
  @spec merge([Ecto.UUID.t()], Ecto.UUID.t()) :: merge_result()
  def merge(contact_ids, canonical_id) when length(contact_ids) >= 2 do
    if canonical_id not in contact_ids do
      {:error, :canonical_not_in_set}
    else
      Repo.transaction(fn ->
        duplicate_ids = List.delete(contact_ids, canonical_id)

        with {:ok, canonical} <- fetch_contact(canonical_id),
             :ok <- transfer_activities(duplicate_ids, canonical_id),
             :ok <- transfer_tags(duplicate_ids, canonical_id),
             :ok <- transfer_custom_fields(duplicate_ids, canonical_id),
             :ok <- soft_delete_duplicates(duplicate_ids),
             {:ok, _record} <- record_merge(canonical_id, duplicate_ids),
             {:ok, updated} <- reload_contact(canonical.id) do
          updated
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  def merge(_ids, _canonical_id), do: {:error, :insufficient_contacts}

  @doc """
  Returns the merge history for a given contact, showing what it was merged from.
  """
  @spec merge_history(Ecto.UUID.t()) :: [MergeRecord.t()]
  def merge_history(contact_id) when is_binary(contact_id) do
    MergeRecord
    |> where([m], m.canonical_id == ^contact_id)
    |> order_by([m], desc: m.merged_at)
    |> Repo.all()
  end

  defp fetch_contact(id) do
    case Repo.get(Contact, id) do
      nil -> {:error, :contact_not_found}
      contact -> {:ok, contact}
    end
  end

  defp transfer_activities(from_ids, to_id) do
    Activity
    |> where([a], a.contact_id in ^from_ids)
    |> Repo.update_all(set: [contact_id: to_id])

    :ok
  end

  defp transfer_tags(from_ids, to_id) do
    existing_tag_names =
      Tag
      |> where([t], t.contact_id == ^to_id)
      |> select([t], t.name)
      |> Repo.all()
      |> MapSet.new()

    Tag
    |> where([t], t.contact_id in ^from_ids and t.name not in ^MapSet.to_list(existing_tag_names))
    |> Repo.update_all(set: [contact_id: to_id])

    Tag
    |> where([t], t.contact_id in ^from_ids)
    |> Repo.delete_all()

    :ok
  end

  defp transfer_custom_fields(from_ids, to_id) do
    CustomField
    |> where([f], f.contact_id in ^from_ids)
    |> Repo.update_all(set: [contact_id: to_id])

    :ok
  end

  defp soft_delete_duplicates(duplicate_ids) do
    now = DateTime.utc_now()

    Contact
    |> where([c], c.id in ^duplicate_ids)
    |> Repo.update_all(set: [deleted_at: now, status: :merged])

    :ok
  end

  defp record_merge(canonical_id, duplicate_ids) do
    %MergeRecord{}
    |> MergeRecord.changeset(%{
      canonical_id: canonical_id,
      merged_ids: duplicate_ids,
      merged_at: DateTime.utc_now()
    })
    |> Repo.insert()
  end

  defp reload_contact(id) do
    case Repo.get(Contact, id) do
      nil -> {:error, :contact_not_found}
      contact -> {:ok, contact}
    end
  end
end
```
