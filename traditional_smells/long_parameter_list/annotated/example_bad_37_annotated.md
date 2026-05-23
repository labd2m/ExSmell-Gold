# Annotated Example 37 — Long Parameter List

## Metadata

| Field | Value |
|---|---|
| **Smell name** | Long Parameter List |
| **Expected smell location** | `Procurement.Vendors.onboard_vendor/11` |
| **Affected function(s)** | `onboard_vendor/11` |
| **Explanation** | The function takes 11 individual parameters covering business identity (company_name, tax_id, registration_number), primary contact (contact_name, contact_email, contact_phone), bank details (bank_name, iban), and classification (category, country_code, payment_terms_days). These belong in a `%CompanyInfo{}`, `%ContactDetails{}`, and `%PaymentConfig{}` struct rather than a flat positional signature. |

---

```elixir
# VALIDATION: SMELL START - Long Parameter List
# VALIDATION: This is a smell because `onboard_vendor/11` accepts eleven
# individual positional parameters. Company identity data (company_name,
# tax_id, registration_number), primary contact information (contact_name,
# contact_email, contact_phone), banking details (bank_name, iban), and
# procurement configuration (category, country_code, payment_terms_days)
# are all threaded through one long flat signature. The three string-typed
# identity fields and two string-typed contact fields are especially
# prone to being supplied in the wrong order at call sites.
defmodule Procurement.Vendors do
  @moduledoc """
  Handles vendor onboarding, compliance checks, banking verification,
  and procurement category assignment.
  """

  require Logger

  alias Procurement.Repo
  alias Procurement.Schemas.Vendor
  alias Procurement.Schemas.ComplianceRecord
  alias Procurement.BankVerifier
  alias Procurement.ComplianceChecker
  alias Procurement.Mailer

  @valid_categories ~w(raw_materials services logistics technology facilities)
  @valid_payment_terms [15, 30, 45, 60, 90]

  def onboard_vendor(
        company_name,
        tax_id,
        registration_number,
        contact_name,
        contact_email,
        contact_phone,
        bank_name,
        iban,
        category,
        country_code,
        payment_terms_days
      ) do
# VALIDATION: SMELL END
    with :ok <- validate_company(company_name, tax_id, registration_number),
         :ok <- validate_contact(contact_name, contact_email, contact_phone),
         :ok <- validate_banking(bank_name, iban),
         :ok <- validate_category(category),
         :ok <- validate_payment_terms(payment_terms_days) do
      compliance = ComplianceChecker.screen(tax_id, registration_number, country_code)

      if compliance.sanctions_match do
        Logger.warn("Sanctions match for vendor #{company_name} / #{tax_id}")
        {:error, :sanctions_match}
      else
        bank_verified = BankVerifier.verify_iban(iban, bank_name)

        vendor_attrs = %{
          company_name: String.trim(company_name),
          tax_id: tax_id,
          registration_number: registration_number,
          contact_name: contact_name,
          contact_email: String.downcase(String.trim(contact_email)),
          contact_phone: contact_phone,
          bank_name: bank_name,
          iban: iban,
          bank_verified: bank_verified,
          category: category,
          country_code: String.upcase(country_code),
          payment_terms_days: payment_terms_days,
          compliance_score: compliance.score,
          status: :active,
          inserted_at: DateTime.utc_now()
        }

        case Repo.insert(Vendor.changeset(%Vendor{}, vendor_attrs)) do
          {:ok, vendor} ->
            Repo.insert!(ComplianceRecord.changeset(%ComplianceRecord{}, %{
              vendor_id: vendor.id,
              screened_at: DateTime.utc_now(),
              score: compliance.score,
              sanctions_match: false,
              screener: compliance.screener
            }))

            Mailer.send_onboarding_welcome(contact_email, contact_name, vendor)
            Logger.info("Vendor #{vendor.id} onboarded: #{company_name} [#{category}]")
            {:ok, vendor}

          {:error, changeset} ->
            Logger.error("Vendor onboarding failed: #{inspect(changeset.errors)}")
            {:error, :onboarding_failed}
        end
      end
    end
  end

  defp validate_company(name, tax_id, reg_number) do
    cond do
      is_nil(name) or String.trim(name) == "" -> {:error, :missing_company_name}
      not Regex.match?(~r/^[A-Z0-9\-]{5,20}$/i, tax_id || "") -> {:error, :invalid_tax_id}
      not Regex.match?(~r/^[A-Z0-9\-]{4,30}$/i, reg_number || "") -> {:error, :invalid_registration_number}
      true -> :ok
    end
  end

  defp validate_contact(name, email, phone) do
    cond do
      is_nil(name) or String.trim(name) == "" -> {:error, :missing_contact_name}
      not Regex.match?(~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, email || "") -> {:error, :invalid_contact_email}
      not Regex.match?(~r/^\+?[1-9]\d{6,14}$/, phone || "") -> {:error, :invalid_contact_phone}
      true -> :ok
    end
  end

  defp validate_banking(bank_name, iban) do
    cond do
      is_nil(bank_name) or String.trim(bank_name) == "" -> {:error, :missing_bank_name}
      not Regex.match?(~r/^[A-Z]{2}\d{2}[A-Z0-9]{11,30}$/, iban || "") -> {:error, :invalid_iban}
      true -> :ok
    end
  end

  defp validate_category(c) when c in @valid_categories, do: :ok
  defp validate_category(c), do: {:error, {:unknown_vendor_category, c}}

  defp validate_payment_terms(d) when d in @valid_payment_terms, do: :ok
  defp validate_payment_terms(d), do: {:error, {:invalid_payment_terms, d}}
end
```
