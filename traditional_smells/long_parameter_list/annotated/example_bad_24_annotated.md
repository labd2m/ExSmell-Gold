# Annotated Example 24 — Long Parameter List

## Metadata

| Field | Value |
|---|---|
| **Smell name** | Long Parameter List |
| **Expected smell location** | `CRM.Contacts.create_contact/10` |
| **Affected function(s)** | `create_contact/10` |
| **Explanation** | The function accepts 10 positional parameters mixing personal data (first_name, last_name, email, phone), company info (company_name, job_title), CRM metadata (owner_id, pipeline_stage, lead_source), and preferences (do_not_contact). These clearly form at least a `%ContactInfo{}` and a `%CRMConfig{}` struct instead of a flat list. |

---

```elixir
# VALIDATION: SMELL START - Long Parameter List
# VALIDATION: This is a smell because `create_contact/10` accepts ten
# positional parameters. Personal data (first_name, last_name, email, phone),
# company affiliation (company_name, job_title), CRM configuration
# (owner_id, pipeline_stage, lead_source), and communication preferences
# (do_not_contact) are all mixed into a single flat signature. This makes
# the function hard to call correctly — especially since three string-typed
# CRM fields and a boolean trail at the end look similar and invite mistakes.
defmodule CRM.Contacts do
  @moduledoc """
  Manages contact creation, deduplication, and pipeline assignment
  in the customer relationship management subsystem.
  """

  require Logger

  alias CRM.Repo
  alias CRM.Schemas.Contact
  alias CRM.Schemas.Activity
  alias CRM.DuplicationChecker
  alias CRM.SearchIndex

  @valid_stages ~w(lead qualified opportunity customer churned)
  @valid_sources ~w(website referral cold_call event social_media import)

  def create_contact(
        first_name,
        last_name,
        email,
        phone,
        company_name,
        job_title,
        owner_id,
        pipeline_stage,
        lead_source,
        do_not_contact
      ) do
# VALIDATION: SMELL END
    with :ok <- validate_name(first_name, :first_name),
         :ok <- validate_name(last_name, :last_name),
         :ok <- validate_email(email),
         :ok <- validate_stage(pipeline_stage),
         :ok <- validate_source(lead_source) do
      case DuplicationChecker.find_by_email(email) do
        {:duplicate, existing_id} ->
          Logger.warn("Duplicate contact detected for #{email}, existing id=#{existing_id}")
          {:error, {:duplicate, existing_id}}

        :unique ->
          contact_attrs = %{
            first_name: String.trim(first_name),
            last_name: String.trim(last_name),
            email: String.downcase(String.trim(email)),
            phone: phone,
            company_name: company_name,
            job_title: job_title,
            owner_id: owner_id,
            pipeline_stage: pipeline_stage,
            lead_source: lead_source,
            do_not_contact: do_not_contact,
            inserted_at: DateTime.utc_now()
          }

          case Repo.insert(Contact.changeset(%Contact{}, contact_attrs)) do
            {:ok, contact} ->
              SearchIndex.index_contact(contact)

              Repo.insert!(Activity.changeset(%Activity{}, %{
                contact_id: contact.id,
                type: :created,
                actor_id: owner_id,
                notes: "Contact created via #{lead_source}",
                occurred_at: DateTime.utc_now()
              }))

              Logger.info("Contact #{contact.id} created: #{email}")
              {:ok, contact}

            {:error, changeset} ->
              Logger.error("Contact creation failed: #{inspect(changeset.errors)}")
              {:error, :creation_failed}
          end
      end
    end
  end

  defp validate_name(name, field) do
    if is_binary(name) and String.length(String.trim(name)) >= 1 do
      :ok
    else
      {:error, {field, :blank}}
    end
  end

  defp validate_email(email) do
    if Regex.match?(~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, email || "") do
      :ok
    else
      {:error, :invalid_email}
    end
  end

  defp validate_stage(s) when s in @valid_stages, do: :ok
  defp validate_stage(s), do: {:error, {:unknown_pipeline_stage, s}}

  defp validate_source(src) when src in @valid_sources, do: :ok
  defp validate_source(src), do: {:error, {:unknown_lead_source, src}}
end
```
