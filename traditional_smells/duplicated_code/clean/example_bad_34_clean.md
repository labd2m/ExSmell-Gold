```elixir
defmodule ContactRepository do
  @moduledoc """
  Provides search, filtering, and export capabilities for the CRM contact database.
  """

  alias CRM.{Contact, Tag, ExportJob, Pagination, ActivityLog}

  @default_page_size 50
  @max_page_size 200
  @max_export_rows 50_000

  def search(params) do
    page = max(Map.get(params, :page, 1), 1)
    page_size = min(Map.get(params, :page_size, @default_page_size), @max_page_size)

    filters =
      []
      |> maybe_add_filter(:name_contains, Map.get(params, :name))
      |> maybe_add_filter(:email_domain, Map.get(params, :email_domain))
      |> maybe_add_tags_filter(Map.get(params, :tags))
      |> maybe_add_date_filter(:created_after, Map.get(params, :created_after))
      |> maybe_add_date_filter(:created_before, Map.get(params, :created_before))

    total = Contact.count(filters)
    contacts = Contact.list(filters, page: page, page_size: page_size)

    {:ok,
     %Pagination{
       data: contacts,
       page: page,
       page_size: page_size,
       total: total,
       total_pages: ceil(total / page_size)
     }}
  end

  def export(params) do
    format = Map.get(params, :format, :csv)
    requested_by = Map.fetch!(params, :user_id)

    filters =
      []
      |> maybe_add_filter(:name_contains, Map.get(params, :name))
      |> maybe_add_filter(:email_domain, Map.get(params, :email_domain))
      |> maybe_add_tags_filter(Map.get(params, :tags))
      |> maybe_add_date_filter(:created_after, Map.get(params, :created_after))
      |> maybe_add_date_filter(:created_before, Map.get(params, :created_before))

    estimated_count = Contact.count(filters)

    if estimated_count > @max_export_rows do
      {:error, {:too_many_rows, estimated_count, @max_export_rows}}
    else
      job = %ExportJob{
        id: Ecto.UUID.generate(),
        requested_by: requested_by,
        filters: filters,
        format: format,
        estimated_rows: estimated_count,
        status: :queued,
        created_at: DateTime.utc_now()
      }

      CRM.Repo.insert(job)
      CRM.ExportWorker.enqueue(job.id)
      ActivityLog.record(requested_by, :export_requested, %{job_id: job.id})
      {:ok, job}
    end
  end

  def merge_contacts(primary_id, duplicate_id) do
    with {:ok, primary} <- Contact.fetch(primary_id),
         {:ok, duplicate} <- Contact.fetch(duplicate_id) do
      merged_tags = Enum.uniq(primary.tags ++ duplicate.tags)
      merged_notes = [primary.notes, duplicate.notes] |> Enum.reject(&is_nil/1) |> Enum.join("\n")

      Contact.update(primary, %{tags: merged_tags, notes: merged_notes})
      Contact.soft_delete(duplicate, merged_into: primary_id)
      {:ok, :merged}
    end
  end

  defp maybe_add_filter(filters, _key, nil), do: filters
  defp maybe_add_filter(filters, key, value), do: [{key, value} | filters]

  defp maybe_add_tags_filter(filters, nil), do: filters
  defp maybe_add_tags_filter(filters, []), do: filters

  defp maybe_add_tags_filter(filters, tags) when is_list(tags) do
    resolved = Tag.resolve_ids(tags)
    [{:tags_include, resolved} | filters]
  end

  defp maybe_add_date_filter(filters, _key, nil), do: filters

  defp maybe_add_date_filter(filters, key, value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> [{key, date} | filters]
      _ -> filters
    end
  end

  defp maybe_add_date_filter(filters, key, %Date{} = date), do: [{key, date} | filters]
end
```
