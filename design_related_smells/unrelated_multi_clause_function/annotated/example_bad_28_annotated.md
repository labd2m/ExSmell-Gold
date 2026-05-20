# Annotated Example 28

- **Smell name:** Unrelated multi-clause function
- **Expected smell location:** `ContractEngine.execute/1`
- **Affected function(s):** `execute/1`
- **Short explanation:** `execute/1` handles contract drafting, contract signing, and contract termination — three unrelated legal document lifecycle operations — collapsed under one multi-clause function. Each represents a distinct legal action with different signatories, compliance obligations, and audit requirements.

```elixir
defmodule ContractEngine do
  @moduledoc """
  Manages the lifecycle of legal contracts on the platform,
  including drafting, execution (signing), and termination workflows.
  """

  alias ContractEngine.{
    DraftRequest,
    SigningRequest,
    TerminationRequest,
    ContractStore,
    TemplateLibrary,
    SignatureService,
    LegalReviewQueue,
    PartyNotifier,
    AuditLog,
    DocumentStore
  }

  require Logger

  @doc """
  Execute a contract lifecycle action.

  Accepts a `%DraftRequest{}`, `%SigningRequest{}`, or `%TerminationRequest{}`
  and performs the corresponding contract operation.

  ## Examples

      iex> ContractEngine.execute(%DraftRequest{template: :nda, parties: [...], term_months: 12})
      {:ok, %Contract{id: "con_001", status: :draft}}

  """
  # VALIDATION: SMELL START - Unrelated multi-clause function
  # VALIDATION: This is a smell because drafting a contract, collecting
  # signatures, and processing a contract termination are entirely separate
  # legal workflows with different actors, different validation requirements,
  # and different downstream obligations (legal review, notarization, and
  # notice periods respectively). Collapsing them into `execute/1` conflates
  # unrelated business logic.

  def execute(%DraftRequest{
        template: template,
        parties: parties,
        term_months: term_months,
        governing_law: governing_law,
        custom_clauses: custom_clauses,
        created_by: created_by
      }) do
    with {:ok, base_template} <- TemplateLibrary.fetch(template),
         {:ok, rendered_content} <-
           TemplateLibrary.render(base_template, %{
             parties: parties,
             term_months: term_months,
             governing_law: governing_law,
             custom_clauses: custom_clauses
           }),
         {:ok, document_url} <- DocumentStore.store_draft(rendered_content),
         {:ok, contract} <-
           ContractStore.create(%{
             template: template,
             parties: Enum.map(parties, & &1.id),
             term_months: term_months,
             governing_law: governing_law,
             document_url: document_url,
             status: :draft,
             created_by: created_by,
             created_at: DateTime.utc_now()
           }),
         :ok <- LegalReviewQueue.enqueue(contract.id),
         :ok <- PartyNotifier.send_draft_for_review(parties, contract) do
      Logger.info("Contract #{contract.id} drafted by #{created_by} using template #{template}")
      {:ok, contract}
    end
  end

  # execute signing workflow — collect signature from a party
  def execute(%SigningRequest{
        contract_id: contract_id,
        signer_id: signer_id,
        signature_data: signature_data,
        ip_address: ip
      }) do
    with {:ok, contract} <- ContractStore.find(contract_id),
         :ok <- validate_contract_signable(contract),
         :ok <- validate_signer_authorized(contract, signer_id),
         {:ok, sig_record} <-
           SignatureService.record_signature(%{
             contract_id: contract_id,
             signer_id: signer_id,
             signature_data: signature_data,
             signed_at: DateTime.utc_now(),
             ip_address: ip
           }),
         all_signed = all_parties_signed?(contract, signer_id),
         {:ok, updated} <-
           ContractStore.update(contract_id, %{
             status: if(all_signed, do: :fully_executed, else: :partially_signed),
             last_signed_at: DateTime.utc_now()
           }),
         :ok <-
           AuditLog.append(:contract_signed, %{
             contract_id: contract_id,
             signer_id: signer_id,
             signature_id: sig_record.id,
             all_signed: all_signed
           }),
         :ok <- PartyNotifier.send_signature_confirmation(signer_id, updated, all_signed) do
      Logger.info("Contract #{contract_id} signed by #{signer_id}; fully_executed=#{all_signed}")
      {:ok, %{contract: updated, fully_executed: all_signed}}
    end
  end

  # execute contract termination with notice period enforcement
  def execute(%TerminationRequest{
        contract_id: contract_id,
        terminating_party_id: party_id,
        reason: reason,
        effective_date: effective_date
      }) do
    with {:ok, contract} <- ContractStore.find(contract_id),
         :ok <- validate_contract_terminable(contract),
         :ok <- validate_notice_period(contract, effective_date),
         {:ok, updated} <-
           ContractStore.update(contract_id, %{
             status: :terminated,
             termination_reason: reason,
             terminated_by: party_id,
             termination_effective_date: effective_date,
             terminated_at: DateTime.utc_now()
           }),
         :ok <-
           AuditLog.append(:contract_terminated, %{
             contract_id: contract_id,
             party_id: party_id,
             reason: reason,
             effective_date: effective_date
           }),
         :ok <- PartyNotifier.send_termination_notice(contract.parties, updated) do
      Logger.info("Contract #{contract_id} terminated by #{party_id}, effective #{effective_date}")
      {:ok, updated}
    end
  end

  # VALIDATION: SMELL END

  defp validate_contract_signable(%{status: :draft}), do: :ok
  defp validate_contract_signable(%{status: :partially_signed}), do: :ok
  defp validate_contract_signable(%{status: s}), do: {:error, {:not_signable, s}}

  defp validate_signer_authorized(%{parties: party_ids}, signer_id) do
    if signer_id in party_ids do
      :ok
    else
      {:error, :signer_not_a_party}
    end
  end

  defp all_parties_signed?(contract, latest_signer_id) do
    signed_ids = contract.signatures |> Enum.map(& &1.signer_id)
    all_ids = [latest_signer_id | signed_ids] |> MapSet.new()
    MapSet.equal?(all_ids, MapSet.new(contract.parties))
  end

  defp validate_contract_terminable(%{status: :fully_executed}), do: :ok
  defp validate_contract_terminable(%{status: s}), do: {:error, {:not_terminable, s}}

  defp validate_notice_period(%{notice_days: notice_days}, effective_date) do
    min_date = Date.add(Date.utc_today(), notice_days)

    if Date.compare(effective_date, min_date) != :lt do
      :ok
    else
      {:error, {:insufficient_notice, notice_days}}
    end
  end
end
```
