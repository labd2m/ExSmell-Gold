```elixir
defmodule CRM.Contacts do
  @moduledoc """
  Manages CRM contact records including creation, updates,
  merging, and archiving. Enforces data quality rules on
  contact attributes before persistence.
  """

  alias CRM.Repo
  alias CRM.Contact
  alias CRM.ActivityLog

  @doc """
  Creates a new contact from the given attributes map.
  Validates and normalizes phone numbers before inserting.
  """
  def create(attrs) do
    phone_result =
      case Map.get(attrs, "phone") do
        nil ->
          {:ok, nil}

        raw ->
          digits = String.replace(raw, ~r/\D/, "")

          cond do
            String.length(digits) == 10 -> {:ok, "+1#{digits}"}
            String.length(digits) == 11 and String.starts_with?(digits, "1") -> {:ok, "+#{digits}"}
            true -> {:error, :invalid_phone}
          end
      end

    case phone_result do
      {:error, reason} ->
        {:error, reason}

      {:ok, normalized_phone} ->
        contact = %Contact{
          first_name: attrs["first_name"],
          last_name: attrs["last_name"],
          email: attrs["email"],
          phone: normalized_phone,
          company: attrs["company"],
          source: attrs["source"] || "manual",
          status: :active
        }

        with {:ok, saved} <- Repo.insert(contact) do
          ActivityLog.record(:contact_created, saved.id)
          {:ok, saved}
        end
    end
  end

  @doc """
  Updates an existing contact with new attribute values.
  Re-normalizes the phone number if one is provided.
  """
  def update(%Contact{} = contact, attrs) do
    phone_result =
      case Map.get(attrs, "phone") do
        nil ->
          {:ok, contact.phone}

        raw ->
          digits = String.replace(raw, ~r/\D/, "")

          cond do
            String.length(digits) == 10 -> {:ok, "+1#{digits}"}
            String.length(digits) == 11 and String.starts_with?(digits, "1") -> {:ok, "+#{digits}"}
            true -> {:error, :invalid_phone}
          end
      end

    case phone_result do
      {:error, reason} ->
        {:error, reason}

      {:ok, normalized_phone} ->
        updated = %{
          contact
          | first_name: Map.get(attrs, "first_name", contact.first_name),
            last_name: Map.get(attrs, "last_name", contact.last_name),
            email: Map.get(attrs, "email", contact.email),
            phone: normalized_phone,
            company: Map.get(attrs, "company", contact.company),
            updated_at: DateTime.utc_now()
        }

        with {:ok, saved} <- Repo.update(updated) do
          ActivityLog.record(:contact_updated, saved.id)
          {:ok, saved}
        end
    end
  end

  @doc """
  Archives a contact so it no longer appears in active lists.
  """
  def archive(%Contact{} = contact) do
    updated = %{contact | status: :archived, archived_at: DateTime.utc_now()}
    Repo.update(updated)
  end

  @doc """
  Merges two contact records, keeping the primary and discarding the duplicate.
  """
  def merge(%Contact{} = primary, %Contact{} = duplicate) do
    Repo.update(%{primary | merged_ids: [duplicate.id | primary.merged_ids || []]})
    Repo.delete(duplicate)
    {:ok, primary}
  end
end
```
