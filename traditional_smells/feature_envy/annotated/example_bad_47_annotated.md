# Code Smell Example – Annotated

- **Smell:** Feature Envy
- **Expected smell location:** `Accounts.ProfileExporter.export_user_record/1`
- **Affected function(s):** `export_user_record/1`
- **Explanation:** `export_user_record/1` calls `UserProfile.get_contact_info/1`, `UserProfile.list_roles/1`, `UserProfile.last_activity/1`, `UserProfile.gdpr_consent/1`, `UserProfile.linked_identities/1`, and reads many struct fields from the profile directly. `ProfileExporter` only provides serialization utilities. The function envies `UserProfile` and should belong there.

```elixir
defmodule Accounts.ProfileExporter do
  @moduledoc """
  Exports user profile data for GDPR data-portability requests and
  internal compliance audits. Produces structured JSON payloads that
  are signed, encrypted, and delivered to the requesting party via
  a secure download link valid for 48 hours.
  """

  alias Accounts.{UserProfile, ContactInfo, LinkedIdentity}
  alias Compliance.{ConsentRecord, AuditTrail}
  alias Crypto.{PayloadSigner, PayloadEncryptor}

  @export_schema_version "3.0"
  @download_link_ttl_seconds 172_800

  # ------------------------------------------------------------------
  # Public API
  # ------------------------------------------------------------------

  @doc """
  Builds, signs, and encrypts the export payload for a single user.
  Returns `{:ok, download_url}` or `{:error, reason}`.
  """
  @spec export(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def export(user_id, opts \\ []) do
    requester = Keyword.get(opts, :requested_by, :self)

    with {:ok, profile}  <- UserProfile.fetch(user_id),
         :active         <- profile.account_status,
         record          <- export_user_record(profile),
         {:ok, signed}   <- PayloadSigner.sign(record),
         {:ok, encrypted} <- PayloadEncryptor.encrypt(signed),
         {:ok, url}      <- store_and_issue_link(user_id, encrypted, requester) do
      AuditTrail.log(:user_data_exported, user_id: user_id, requested_by: requester)
      {:ok, url}
    else
      :suspended -> {:error, :account_suspended}
      error      -> error
    end
  end

  # ------------------------------------------------------------------
  # Private helpers
  # ------------------------------------------------------------------

  # VALIDATION: SMELL START - Feature Envy
  # VALIDATION: This is a smell because export_user_record/1 is defined in
  # VALIDATION: ProfileExporter but almost exclusively operates on UserProfile
  # VALIDATION: data. It calls:
  # VALIDATION:   - UserProfile.get_contact_info/1
  # VALIDATION:   - UserProfile.list_roles/1
  # VALIDATION:   - UserProfile.last_activity/1
  # VALIDATION:   - UserProfile.gdpr_consent/1
  # VALIDATION:   - UserProfile.linked_identities/1
  # VALIDATION: and reads profile.id, profile.username, profile.display_name,
  # VALIDATION: profile.locale, profile.timezone, profile.created_at,
  # VALIDATION: and profile.metadata directly from the struct.
  # VALIDATION: ProfileExporter contributes only the wrapping schema version
  # VALIDATION: header and timestamp. The function belongs in UserProfile.
  defp export_user_record(profile) do
    contact     = UserProfile.get_contact_info(profile)
    roles       = UserProfile.list_roles(profile)
    last_active = UserProfile.last_activity(profile)
    consent     = UserProfile.gdpr_consent(profile)
    identities  = UserProfile.linked_identities(profile)

    role_names  = Enum.map(roles, & &1.name)

    identity_entries =
      Enum.map(identities, fn id ->
        %{
          provider:    id.provider,
          provider_id: LinkedIdentity.masked_id(id),
          linked_at:   format_iso(id.linked_at)
        }
      end)

    %{
      schema_version:   @export_schema_version,
      exported_at:      DateTime.utc_now() |> DateTime.to_iso8601(),
      account: %{
        id:               profile.id,
        username:         profile.username,
        display_name:     profile.display_name,
        locale:           profile.locale,
        timezone:         profile.timezone,
        created_at:       format_iso(profile.created_at),
        last_active_at:   format_iso(last_active),
        roles:            role_names
      },
      contact: %{
        email:            contact.email,
        email_verified:   contact.email_verified,
        phone:            ContactInfo.masked_phone(contact),
        phone_verified:   contact.phone_verified
      },
      linked_identities: identity_entries,
      consent: %{
        marketing:        ConsentRecord.granted?(consent, :marketing),
        analytics:        ConsentRecord.granted?(consent, :analytics),
        third_party:      ConsentRecord.granted?(consent, :third_party),
        last_updated_at:  format_iso(consent.updated_at)
      },
      metadata: profile.metadata
    }
  end
  # VALIDATION: SMELL END

  defp store_and_issue_link(user_id, payload, requester) do
    key     = "exports/#{user_id}/#{System.unique_integer([:positive])}"
    expires = DateTime.add(DateTime.utc_now(), @download_link_ttl_seconds)

    with {:ok, _} <- Storage.put(key, payload, expires: expires) do
      {:ok, Storage.signed_url(key, ttl: @download_link_ttl_seconds, actor: requester)}
    end
  end

  defp format_iso(nil),             do: nil
  defp format_iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_iso(%Date{} = d),      do: Date.to_iso8601(d)
end
```
