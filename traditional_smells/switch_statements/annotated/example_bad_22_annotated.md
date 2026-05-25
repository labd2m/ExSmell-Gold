# Annotated Example — Switch Statements

## Metadata

- **Smell name:** Switch Statements
- **Expected smell location:** `KycPolicy` module — functions `transaction_limit_cents/1`, `required_documents/1`, and `review_queue/1`
- **Affected functions:** `transaction_limit_cents/1`, `required_documents/1`, `review_queue/1`
- **Short explanation:** The same `case level` branching over `:none`, `:basic`, `:enhanced`, and `:full` is duplicated across three functions. Adding a new KYC verification level requires updating all three case blocks independently, which is the Switch Statements smell.

---

```elixir
defmodule KycPolicy do
  @moduledoc """
  Enforces Know Your Customer (KYC) compliance rules for the fintech platform.
  Determines transaction limits, required verification documents, and
  review queue routing based on a user's current verification level.
  """

  require Logger

  @levels [:none, :basic, :enhanced, :full]

  def valid_levels, do: @levels

  # VALIDATION: SMELL START - Switch Statements
  # VALIDATION: This is a smell because the same case branching over level
  # (:none, :basic, :enhanced, :full) is duplicated in transaction_limit_cents/1,
  # required_documents/1, and review_queue/1. Any new KYC level demands changes
  # to all three case expressions independently.

  @doc """
  Returns the maximum single-transaction amount in cents permitted for a user
  at the given verification level.
  """
  def transaction_limit_cents(%{kyc_level: level}) do
    case level do
      :none -> 5_000
      :basic -> 50_000
      :enhanced -> 500_000
      :full -> :unlimited
      _ -> 5_000
    end
  end

  @doc """
  Returns the list of document types that must be collected and approved before
  a user can be upgraded to the given verification level.
  """
  def required_documents(%{kyc_level: level}) do
    case level do
      :none ->
        []

      :basic ->
        [:government_id]

      :enhanced ->
        [:government_id, :proof_of_address]

      :full ->
        [:government_id, :proof_of_address, :source_of_funds, :tax_id]

      _ ->
        [:government_id]
    end
  end

  @doc """
  Returns the name of the compliance review queue to which a verification
  submission should be routed for manual review.
  """
  def review_queue(%{kyc_level: level}) do
    case level do
      :none -> "kyc_tier0_review"
      :basic -> "kyc_tier1_review"
      :enhanced -> "kyc_tier2_review"
      :full -> "kyc_tier3_review"
      _ -> "kyc_general_review"
    end
  end

  # VALIDATION: SMELL END

  @doc """
  Checks whether a user is permitted to execute a transaction of the given amount.
  """
  def transaction_permitted?(%{kyc_level: _} = user, amount_cents) when is_integer(amount_cents) do
    case transaction_limit_cents(user) do
      :unlimited -> true
      limit -> amount_cents <= limit
    end
  end

  @doc """
  Evaluates which documents are still missing for the user to reach the target level.
  """
  def missing_documents(%{kyc_level: _} = target, %{submitted_documents: submitted}) do
    required = required_documents(target)
    Enum.reject(required, fn doc -> doc in submitted end)
  end

  @doc """
  Initiates a KYC upgrade request for a user, routing the submission to the
  appropriate compliance queue.
  """
  def request_upgrade(%{id: user_id, kyc_level: current_level} = user, target_level, documents) do
    target = %{kyc_level: target_level}
    missing = missing_documents(target, %{submitted_documents: Enum.map(documents, & &1.type)})

    if Enum.any?(missing) do
      Logger.warning("KYC upgrade request for user #{user_id} missing: #{inspect(missing)}.")
      {:error, {:missing_documents, missing}}
    else
      queue = review_queue(target)

      submission = %{
        user_id: user_id,
        current_level: current_level,
        target_level: target_level,
        documents: documents,
        queue: queue,
        submitted_at: DateTime.utc_now(),
        status: :pending
      }

      Logger.info("KYC upgrade for #{user_id} submitted to queue '#{queue}'.")
      {:ok, submission}
    end
  end

  @doc """
  Returns the effective spending capacity for the user over a rolling 30-day window.
  """
  def monthly_capacity(%{} = user, already_spent_cents) do
    case transaction_limit_cents(user) do
      :unlimited ->
        :unlimited

      limit ->
        remaining = max(0, limit * 30 - already_spent_cents)
        %{daily_limit: limit, monthly_limit: limit * 30, remaining: remaining}
    end
  end

  @doc """
  Validates that a user's KYC level is a recognized value.
  """
  def validate_level(%{kyc_level: level}) when level in @levels, do: :ok
  def validate_level(%{kyc_level: unknown}), do: {:error, {:unknown_kyc_level, unknown}}
  def validate_level(_), do: {:error, :missing_kyc_level}

  @doc """
  Generates a compliance summary report for an individual user.
  """
  def compliance_summary(%{id: user_id} = user) do
    %{
      user_id: user_id,
      kyc_level: user.kyc_level,
      transaction_limit: transaction_limit_cents(user),
      required_docs: required_documents(user),
      review_queue: review_queue(user)
    }
  end
end
```
