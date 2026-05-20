# Annotated Example 41

- **Smell name:** Unrelated multi-clause function
- **Expected smell location:** `PartnerPortal.submit/1`
- **Affected function(s):** `submit/1`
- **Short explanation:** `submit/1` handles partner application onboarding, API key provisioning, and revenue share payout requests — three unrelated B2B partner portal operations — merged under one multi-clause function. Each involves separate approval flows, compliance checks, and external integrations.

```elixir
defmodule PartnerPortal do
  @moduledoc """
  B2B partner portal operations including partner application processing,
  API credential provisioning, and revenue share payout request handling.
  """

  alias PartnerPortal.{
    PartnerApplication,
    ApiKeyRequest,
    PayoutRequest,
    PartnerStore,
    ApiCredentialStore,
    PayoutStore,
    ComplianceVerifier,
    KeyGenerator,
    PaymentRouter,
    ReviewQueue,
    PartnerMailer,
    AuditLog
  }

  require Logger

  @doc """
  Submit a partner portal action.

  Accepts a `%PartnerApplication{}`, `%ApiKeyRequest{}`, or `%PayoutRequest{}`
  and performs the corresponding partner workflow.

  ## Examples

      iex> PartnerPortal.submit(%PartnerApplication{company: "Acme Corp", contact_email: "bd@acme.com"})
      {:ok, %{application_id: "app_001", status: :under_review}}

  """
  # VALIDATION: SMELL START - Unrelated multi-clause function
  # VALIDATION: This is a smell because processing a new partner application
  # (KYB compliance, legal review), provisioning API credentials (scoping,
  # rate-limit tiers), and handling revenue share payouts (financial
  # reconciliation, bank transfer initiation) are entirely different B2B
  # operations with different actors, risk surfaces, and external integrations.
  # Merging them under `submit/1` conflates unrelated partner portal workflows.

  def submit(%PartnerApplication{
        company_name: company,
        contact_email: email,
        business_type: biz_type,
        website: website,
        proposed_use_case: use_case,
        country: country
      }) do
    with :ok <- validate_company_not_already_partner(company),
         {:ok, kyb_result} <- ComplianceVerifier.run_kyb(company, country),
         :ok <- validate_kyb_passed(kyb_result),
         {:ok, application} <-
           PartnerStore.create_application(%{
             company_name: company,
             contact_email: email,
             business_type: biz_type,
             website: website,
             use_case: use_case,
             country: country,
             kyb_reference: kyb_result.reference_id,
             status: :under_review,
             submitted_at: DateTime.utc_now()
           }),
         :ok <- ReviewQueue.enqueue(:partner_application, application.id),
         :ok <- PartnerMailer.send_application_received(email, application) do
      Logger.info("Partner application #{application.id} submitted for #{company}")
      {:ok, %{application_id: application.id, status: :under_review}}
    end
  end

  # submit API key provisioning request for an approved partner
  def submit(%ApiKeyRequest{
        partner_id: partner_id,
        environment: env,
        scopes: scopes,
        rate_limit_tier: tier,
        label: label,
        requested_by: requester
      })
      when env in [:sandbox, :production] do
    with {:ok, partner} <- PartnerStore.find(partner_id),
         :ok <- validate_partner_approved(partner),
         :ok <- validate_scopes_permitted(scopes, partner.allowed_scopes),
         {:ok, raw_key} <- KeyGenerator.generate(),
         {:ok, credential} <-
           ApiCredentialStore.create(%{
             partner_id: partner_id,
             environment: env,
             key_hash: hash_key(raw_key),
             key_prefix: String.slice(raw_key, 0, 8),
             scopes: scopes,
             rate_limit_tier: tier,
             label: label,
             created_by: requester,
             status: :active,
             created_at: DateTime.utc_now()
           }),
         :ok <-
           AuditLog.append(:api_key_provisioned, %{
             partner_id: partner_id,
             credential_id: credential.id,
             env: env,
             by: requester
           }),
         :ok <- PartnerMailer.send_api_key(partner.contact_email, raw_key, env, label) do
      Logger.info("API key #{credential.id} provisioned for partner #{partner_id} in #{env}")
      {:ok, %{credential_id: credential.id, key_prefix: credential.key_prefix, environment: env}}
    end
  end

  # submit revenue share payout request from partner
  def submit(%PayoutRequest{
        partner_id: partner_id,
        period: period,
        bank_account_id: bank_account_id,
        requested_by: requester
      }) do
    with {:ok, partner} <- PartnerStore.find(partner_id),
         :ok <- validate_partner_approved(partner),
         {:ok, balance} <- PayoutStore.get_unpaid_balance(partner_id, period),
         :ok <- validate_minimum_payout(balance),
         {:ok, bank_account} <- PartnerStore.find_bank_account(bank_account_id, partner_id),
         {:ok, payout} <-
           PayoutStore.create(%{
             partner_id: partner_id,
             period: period,
             amount: balance.amount,
             currency: balance.currency,
             bank_account_id: bank_account_id,
             status: :pending,
             requested_by: requester,
             requested_at: DateTime.utc_now()
           }),
         {:ok, transfer} <- PaymentRouter.initiate_bank_transfer(bank_account, balance.amount, payout.id),
         {:ok, _} <- PayoutStore.update(payout.id, %{transfer_id: transfer.id, status: :processing}),
         :ok <- PartnerMailer.send_payout_initiated(partner.contact_email, payout, transfer) do
      Logger.info("Payout #{payout.id} initiated for partner #{partner_id}: #{balance.amount} #{balance.currency}")
      {:ok, %{payout_id: payout.id, amount: balance.amount, currency: balance.currency}}
    end
  end

  # VALIDATION: SMELL END

  defp validate_company_not_already_partner(company_name) do
    case PartnerStore.find_by_company(company_name) do
      {:ok, _} -> {:error, :company_already_a_partner}
      {:error, :not_found} -> :ok
    end
  end

  defp validate_kyb_passed(%{status: :passed}), do: :ok
  defp validate_kyb_passed(%{status: :failed, reason: reason}), do: {:error, {:kyb_failed, reason}}
  defp validate_kyb_passed(%{status: :pending}), do: {:error, :kyb_still_pending}

  defp validate_partner_approved(%{status: :approved}), do: :ok
  defp validate_partner_approved(%{status: s}), do: {:error, {:partner_not_approved, s}}

  defp validate_scopes_permitted(requested, allowed) do
    disallowed = MapSet.difference(MapSet.new(requested), MapSet.new(allowed))
    if MapSet.size(disallowed) == 0, do: :ok, else: {:error, {:scopes_not_permitted, MapSet.to_list(disallowed)}}
  end

  defp validate_minimum_payout(%{amount: amount}) when amount >= 10_000, do: :ok
  defp validate_minimum_payout(_), do: {:error, :below_minimum_payout_threshold}

  defp hash_key(key), do: :crypto.hash(:sha256, key) |> Base.encode64()
end
```
