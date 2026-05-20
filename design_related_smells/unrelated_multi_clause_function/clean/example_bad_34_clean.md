```elixir
defmodule InsurancePolicy do
  @moduledoc """
  Core insurance policy management module.
  Handles policy issuance, claims filing, and annual renewal processing
  for the insurance platform.
  """

  alias InsurancePolicy.{
    IssuanceRequest,
    ClaimRequest,
    RenewalRequest,
    PolicyStore,
    ClaimStore,
    UnderwritingEngine,
    PremiumCalculator,
    DocumentGenerator,
    RegulatoryFiler,
    CustomerMailer
  }

  require Logger

  @doc """
  Apply an insurance lifecycle action.

  Accepts a `%IssuanceRequest{}`, `%ClaimRequest{}`, or `%RenewalRequest{}`
  and performs the corresponding insurance operation.

  ## Examples

      iex> InsurancePolicy.apply(%IssuanceRequest{customer_id: 1, product: :home, coverage: 500_000_00})
      {:ok, %Policy{id: "pol_001", status: :active}}

  """
  def apply(%IssuanceRequest{
        customer_id: customer_id,
        product: product,
        coverage: coverage_amount,
        deductible: deductible,
        effective_date: effective_date,
        beneficiaries: beneficiaries
      }) do
    with {:ok, risk_profile} <- UnderwritingEngine.assess(customer_id, product, coverage_amount),
         :ok <- validate_risk_acceptable(risk_profile),
         {:ok, premium} <-
           PremiumCalculator.compute(%{
             product: product,
             coverage: coverage_amount,
             deductible: deductible,
             risk_score: risk_profile.score
           }),
         {:ok, policy} <-
           PolicyStore.create(%{
             customer_id: customer_id,
             product: product,
             coverage_amount: coverage_amount,
             deductible: deductible,
             annual_premium: premium.annual,
             effective_date: effective_date,
             expiry_date: Date.add(effective_date, 365),
             beneficiaries: beneficiaries,
             status: :active
           }),
         {:ok, policy_doc_url} <- DocumentGenerator.generate_policy_document(policy),
         :ok <- RegulatoryFiler.submit_issuance(policy),
         :ok <- CustomerMailer.send_policy_issued(customer_id, policy, policy_doc_url) do
      Logger.info("Policy #{policy.id} issued for customer #{customer_id} (#{product})")
      {:ok, policy}
    end
  end

  # apply claim filing against an existing active policy
  def apply(%ClaimRequest{
        policy_id: policy_id,
        customer_id: customer_id,
        incident_date: incident_date,
        description: description,
        estimated_loss: estimated_loss,
        supporting_docs: docs
      }) do
    with {:ok, policy} <- PolicyStore.find(policy_id),
         :ok <- validate_policy_active(policy),
         :ok <- validate_customer_owns_policy(policy, customer_id),
         :ok <- validate_incident_within_coverage(policy, incident_date),
         {:ok, claim} <-
           ClaimStore.create(%{
             policy_id: policy_id,
             customer_id: customer_id,
             incident_date: incident_date,
             description: description,
             estimated_loss: estimated_loss,
             supporting_docs: docs,
             status: :under_review,
             filed_at: DateTime.utc_now()
           }),
         :ok <- RegulatoryFiler.submit_claim(claim),
         :ok <- CustomerMailer.send_claim_received(customer_id, claim) do
      Logger.info("Claim #{claim.id} filed against policy #{policy_id}")
      {:ok, claim}
    end
  end

  # apply policy renewal for expiring policy
  def apply(%RenewalRequest{
        policy_id: policy_id,
        customer_id: customer_id,
        coverage_changes: changes
      }) do
    with {:ok, policy} <- PolicyStore.find(policy_id),
         :ok <- validate_renewal_eligible(policy),
         {:ok, risk_profile} <- UnderwritingEngine.assess(customer_id, policy.product, policy.coverage_amount),
         new_coverage = Map.get(changes, :coverage_amount, policy.coverage_amount),
         {:ok, new_premium} <-
           PremiumCalculator.compute(%{
             product: policy.product,
             coverage: new_coverage,
             deductible: Map.get(changes, :deductible, policy.deductible),
             risk_score: risk_profile.score,
             renewal_discount: compute_loyalty_discount(policy)
           }),
         {:ok, renewed} <-
           PolicyStore.renew(policy_id, %{
             coverage_amount: new_coverage,
             annual_premium: new_premium.annual,
             effective_date: policy.expiry_date,
             expiry_date: Date.add(policy.expiry_date, 365),
             status: :active
           }),
         :ok <- RegulatoryFiler.submit_renewal(renewed),
         :ok <- CustomerMailer.send_renewal_confirmation(customer_id, renewed) do
      Logger.info("Policy #{policy_id} renewed for customer #{customer_id}")
      {:ok, renewed}
    end
  end

  defp validate_risk_acceptable(%{score: score}) when score <= 75, do: :ok
  defp validate_risk_acceptable(_), do: {:error, :risk_too_high}

  defp validate_policy_active(%{status: :active}), do: :ok
  defp validate_policy_active(%{status: s}), do: {:error, {:policy_not_active, s}}

  defp validate_customer_owns_policy(%{customer_id: id}, id), do: :ok
  defp validate_customer_owns_policy(_, _), do: {:error, :policy_not_owned_by_customer}

  defp validate_incident_within_coverage(policy, incident_date) do
    if Date.compare(incident_date, policy.effective_date) != :lt and
         Date.compare(incident_date, policy.expiry_date) != :gt do
      :ok
    else
      {:error, :incident_outside_coverage_period}
    end
  end

  defp validate_renewal_eligible(%{expiry_date: expiry}) do
    days_to_expiry = Date.diff(expiry, Date.utc_today())
    if days_to_expiry <= 60, do: :ok, else: {:error, :too_early_to_renew}
  end

  defp compute_loyalty_discount(policy) do
    years = div(Date.diff(Date.utc_today(), policy.effective_date), 365)
    min(years * 0.01, 0.05)
  end
end
```
