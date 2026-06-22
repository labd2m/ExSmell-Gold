```elixir
defmodule Marketplace.Sellers.OnboardingWorkflow do
  @moduledoc """
  Manages multi-step seller onboarding through identity verification,
  bank account validation, and policy agreement steps.

  Each step is independently resumable, allowing sellers to complete
  onboarding across multiple sessions.
  """

  alias Marketplace.Sellers.{SellerProfile, IdentityVerifier, BankValidator, PolicyAgreement}
  alias Marketplace.Repo
  import Ecto.Query, warn: false

  @type step :: :identity | :bank_account | :policy_agreement | :complete
  @type step_result :: {:ok, SellerProfile.t()} | {:error, step_error()}
  @type step_error ::
          {:verification_failed, String.t()}
          | {:validation_failed, String.t()}
          | :already_complete
          | Ecto.Changeset.t()

  @doc """
  Returns the next pending onboarding step for a seller profile.
  """
  @spec next_step(SellerProfile.t()) :: step()
  def next_step(%SellerProfile{identity_verified: false}), do: :identity
  def next_step(%SellerProfile{bank_account_validated: false}), do: :bank_account
  def next_step(%SellerProfile{policy_agreed: false}), do: :policy_agreement
  def next_step(%SellerProfile{}), do: :complete

  @doc """
  Submits identity verification documents for a seller.

  Returns `{:ok, updated_profile}` upon successful verification.
  """
  @spec verify_identity(SellerProfile.t(), map()) :: step_result()
  def verify_identity(%SellerProfile{identity_verified: false} = profile, documents) do
    with {:ok, verification_id} <- IdentityVerifier.submit(profile.id, documents),
         {:ok, updated} <- mark_identity_verified(profile, verification_id) do
      {:ok, updated}
    else
      {:error, reason} -> {:error, {:verification_failed, reason}}
    end
  end

  def verify_identity(%SellerProfile{onboarding_status: :complete}, _documents) do
    {:error, :already_complete}
  end

  def verify_identity(%SellerProfile{}, _documents), do: {:error, {:verification_failed, "already verified"}}

  @doc """
  Validates and stores a seller's bank account details.
  """
  @spec validate_bank_account(SellerProfile.t(), map()) :: step_result()
  def validate_bank_account(%SellerProfile{bank_account_validated: false} = profile, details) do
    with {:ok, account_token} <- BankValidator.validate(details),
         {:ok, updated} <- save_bank_account(profile, account_token) do
      {:ok, updated}
    else
      {:error, reason} -> {:error, {:validation_failed, reason}}
    end
  end

  def validate_bank_account(%SellerProfile{}, _details) do
    {:error, {:validation_failed, "already validated"}}
  end

  @doc """
  Records the seller's agreement to the current policy version.
  """
  @spec record_policy_agreement(SellerProfile.t(), String.t()) :: step_result()
  def record_policy_agreement(%SellerProfile{policy_agreed: false} = profile, policy_version) do
    attrs = %{
      policy_agreed: true,
      policy_version: policy_version,
      policy_agreed_at: DateTime.utc_now()
    }

    with {:ok, updated} <- update_profile(profile, attrs) do
      maybe_complete_onboarding(updated)
    end
  end

  def record_policy_agreement(%SellerProfile{}, _version), do: {:error, :already_complete}

  defp mark_identity_verified(profile, verification_id) do
    update_profile(profile, %{identity_verified: true, identity_verification_id: verification_id})
  end

  defp save_bank_account(profile, account_token) do
    update_profile(profile, %{bank_account_validated: true, bank_account_token: account_token})
  end

  defp maybe_complete_onboarding(%SellerProfile{} = profile) do
    if next_step(profile) == :complete do
      update_profile(profile, %{onboarding_status: :complete, onboarding_completed_at: DateTime.utc_now()})
    else
      {:ok, profile}
    end
  end

  defp update_profile(profile, attrs) do
    profile
    |> SellerProfile.onboarding_changeset(attrs)
    |> Repo.update()
  end
end
```
