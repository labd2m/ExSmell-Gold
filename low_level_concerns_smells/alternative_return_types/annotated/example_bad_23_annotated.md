# Code Smell: Alternative Return Types

## Metadata

- **Smell name:** Alternative Return Types
- **Expected smell location:** `CRM.ContactQuery.find/2`
- **Affected function(s):** `find/2`
- **Short explanation:** The `:projection` option changes the return from a `%Contact{}` struct, to a plain map of selected fields, to a `{:ok, contact, score}` tuple that includes a lead score. Each shape is structurally incompatible with the others and requires different downstream handling.

---

```elixir
defmodule MyApp.CRM.ContactQuery do
  @moduledoc """
  Queries and enriches contact records from the CRM. Supports lightweight
  field projections for list views, full record fetches for detail pages,
  and scored lookups for lead prioritisation workflows.
  """

  alias MyApp.Repo
  alias MyApp.CRM.Contact
  alias MyApp.CRM.LeadScorer
  alias MyApp.CRM.ActivitySummary

  @default_projection :full
  @scorable_statuses [:lead, :prospect, :mql, :sql]

  defstruct [
    :id, :email, :first_name, :last_name,
    :company, :title, :phone,
    :status, :owner_id, :tags,
    :inserted_at, :last_activity_at
  ]

  def list(filters \\ [], opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    page_size = Keyword.get(opts, :page_size, 25)
    Contact
    |> Contact.apply_filters(filters)
    |> Contact.paginate(page, page_size)
    |> Repo.all()
  end

  # VALIDATION: SMELL START - Alternative Return Types
  # VALIDATION: This is a smell because opts[:projection] changes the return
  # type entirely: :full returns a %Contact{} struct, :summary returns a plain
  # map with only the requested keys (e.g. %{id: ..., email: ..., status: ...}),
  # and :scored returns {:ok, %Contact{}, score_map} — a three-element tuple
  # including a computed lead score. These shapes are incompatible: code that
  # expects a struct will crash on a map, and neither handles the tuple.
  def find(contact_id, opts \\ []) when is_list(opts) do
    projection = Keyword.get(opts, :projection, @default_projection)
    fields = Keyword.get(opts, :fields, [:id, :email, :first_name, :last_name, :status])
    with_activity = Keyword.get(opts, :with_activity, false)

    case Repo.get(Contact, contact_id) do
      nil ->
        {:error, :not_found}

      contact ->
        enriched =
          if with_activity do
            summary = ActivitySummary.for_contact(contact_id)
            Map.put(contact, :activity_summary, summary)
          else
            contact
          end

        case projection do
          :full ->
            enriched

          :summary ->
            Map.take(enriched, fields)

          :scored ->
            score =
              if contact.status in @scorable_statuses do
                LeadScorer.score(contact)
              else
                %{total: 0, breakdown: [], grade: :unscored}
              end

            {:ok, enriched, score}
        end
    end
  end
  # VALIDATION: SMELL END

  def by_email(email) do
    case Repo.get_by(Contact, email: String.downcase(email)) do
      nil -> {:error, :not_found}
      contact -> {:ok, contact}
    end
  end

  def update(contact_id, attrs) do
    with contact when not is_nil(contact) <- Repo.get(Contact, contact_id) do
      updated = struct(contact, Map.put(attrs, :updated_at, DateTime.utc_now()))
      Repo.update(updated)
    else
      nil -> {:error, :not_found}
    end
  end

  def assign_owner(contact_id, owner_id) do
    update(contact_id, %{owner_id: owner_id})
  end

  def add_tag(contact_id, tag) do
    with {:ok, contact} <- find(contact_id) |> wrap_struct_result() do
      tags = Enum.uniq([tag | contact.tags])
      update(contact_id, %{tags: tags})
    end
  end

  defp wrap_struct_result(%Contact{} = c), do: {:ok, c}
  defp wrap_struct_result(other), do: other
end
```
