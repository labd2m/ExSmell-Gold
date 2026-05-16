# Annotated Bad Example 19

- **Smell name:** Complex else clauses in with
- **Expected smell location:** `sign_contract/3`, inside the `with` block's `else` clause
- **Affected function(s):** `sign_contract/3`
- **Short explanation:** Contract signing involves fetching the contract, verifying the signer identity, checking signing authority, applying a digital signature, and notifying all parties. All distinct error shapes from these five steps are merged into a single `else` block, hiding which step originated each failure.

```elixir
defmodule Contracts.SigningService do
  alias Contracts.{Repo, Contract, Signer, SignatureEngine, NotificationService, AuditLog}

  require Logger

  def sign_contract(contract_id, signer_id, signature_payload) do
    with {:ok, contract} <- fetch_signable_contract(contract_id),
         {:ok, signer} <- fetch_authorized_signer(signer_id, contract),
         :ok <- verify_signing_authority(signer, contract),
         {:ok, signature} <- SignatureEngine.apply(contract, signer, signature_payload),
         {:ok, updated_contract} <- record_signature(contract, signer, signature) do
      AuditLog.record(:contract_signed, %{
        contract_id: contract_id,
        signer_id: signer_id,
        signature_id: signature.id,
        signed_at: DateTime.utc_now()
      })

      if all_parties_signed?(updated_contract) do
        finalize_contract(updated_contract)
        NotificationService.broadcast(:contract_fully_executed, updated_contract)
      else
        NotificationService.notify_pending_signers(updated_contract)
      end

      Logger.info("Contract #{contract_id} signed by signer #{signer_id}")
      {:ok, updated_contract}
    else
      # VALIDATION: SMELL START - Complex else clauses in with
      # VALIDATION: This is a smell because errors from five independent steps are handled
      # in one `else` block. `:not_found`, `:already_executed`, and `:expired` originate
      # from contract fetching; `:signer_not_found` and `:not_a_party` from signer
      # verification; `:already_signed` and `:unauthorized_delegate` from authority
      # checking; `{:signature_error, _}` from signature application; and `:record_failed`
      # from persistence — all mixed with no indication of their originating step.
      {:error, :not_found} ->
        Logger.warning("Contract #{contract_id} not found")
        {:error, :contract_not_found}

      {:error, :already_executed} ->
        Logger.warning("Contract #{contract_id} is already fully executed")
        {:error, :contract_already_executed}

      {:error, :expired} ->
        Logger.warning("Contract #{contract_id} has expired")
        {:error, :contract_expired}

      {:error, :signer_not_found} ->
        Logger.warning("Signer #{signer_id} not found")
        {:error, :signer_not_found}

      {:error, :not_a_party} ->
        Logger.warning("Signer #{signer_id} is not a party to contract #{contract_id}")
        {:error, :unauthorized_signer}

      {:error, :already_signed} ->
        Logger.info("Signer #{signer_id} already signed contract #{contract_id}")
        {:error, :already_signed}

      {:error, :unauthorized_delegate} ->
        Logger.warning("Signer #{signer_id} does not have delegated signing authority")
        {:error, :insufficient_authority}

      {:error, {:signature_error, reason}} ->
        Logger.error("Signature application failed for contract #{contract_id}: #{inspect(reason)}")
        {:error, :signature_failed}

      {:error, :record_failed} ->
        Logger.error("Signature record persistence failed for contract #{contract_id}")
        {:error, :persistence_error}
      # VALIDATION: SMELL END
    end
  end

  defp fetch_signable_contract(contract_id) do
    case Repo.get(Contract, contract_id) do
      nil -> {:error, :not_found}
      %Contract{status: :executed} -> {:error, :already_executed}
      %Contract{expires_at: exp} = contract when not is_nil(exp) ->
        if DateTime.compare(DateTime.utc_now(), exp) == :gt do
          {:error, :expired}
        else
          {:ok, contract}
        end
      contract -> {:ok, contract}
    end
  end

  defp fetch_authorized_signer(signer_id, contract) do
    case Repo.get(Signer, signer_id) do
      nil ->
        {:error, :signer_not_found}

      signer ->
        if signer.id in Enum.map(contract.required_signers, & &1.id) do
          {:ok, signer}
        else
          {:error, :not_a_party}
        end
    end
  end

  defp verify_signing_authority(signer, contract) do
    cond do
      signer_already_signed?(signer, contract) -> {:error, :already_signed}
      !has_signing_authority?(signer, contract) -> {:error, :unauthorized_delegate}
      true -> :ok
    end
  end

  defp record_signature(contract, signer, signature) do
    contract
    |> Contract.add_signature_changeset(%{signer_id: signer.id, signature_id: signature.id})
    |> Repo.update()
    |> case do
      {:ok, c} -> {:ok, c}
      {:error, _} -> {:error, :record_failed}
    end
  end

  defp all_parties_signed?(contract) do
    Enum.all?(contract.required_signers, fn s ->
      Enum.any?(contract.signatures, &(&1.signer_id == s.id))
    end)
  end

  defp finalize_contract(contract) do
    contract |> Contract.changeset(%{status: :executed, executed_at: DateTime.utc_now()}) |> Repo.update()
  end

  defp signer_already_signed?(signer, contract) do
    Enum.any?(contract.signatures, &(&1.signer_id == signer.id))
  end

  defp has_signing_authority?(signer, contract) do
    signer.role in [:principal, :authorized_delegate] or
      Enum.any?(contract.delegations, &(&1.delegatee_id == signer.id))
  end
end
```
