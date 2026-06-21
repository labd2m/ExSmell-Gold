```elixir
defmodule Contracts.SignatureWorkflow do
  @moduledoc """
  Orchestrates the electronic signature workflow for contracts. A contract
  requires signatures from all designated signatories in an ordered sequence.
  The workflow tracks completion status, notifies the next signatory when
  it is their turn, and finalises the contract once all parties have signed.
  """

  alias MyApp.Repo
  alias Contracts.{Contract, Signatory}
  alias Notifications.Dispatcher, as: Notify

  import Ecto.Query, warn: false

  @type contract_id :: Ecto.UUID.t()
  @type signatory_id :: String.t()

  @type sign_result ::
          {:ok, :signed}
          | {:ok, :completed}
          | {:error, :contract_not_found | :not_your_turn | :already_signed | :contract_finalised}

  @doc "Fetches a contract and its signatories in signing-order."
  @spec fetch_contract(contract_id()) :: {:ok, Contract.t()} | {:error, :not_found}
  def fetch_contract(contract_id) when is_binary(contract_id) do
    query =
      from c in Contract,
        where: c.id == ^contract_id,
        preload: [signatories: ^from(s in Signatory, order_by: s.order)]

    case Repo.one(query) do
      nil -> {:error, :not_found}
      contract -> {:ok, contract}
    end
  end

  @doc """
  Records a signature from `signatory_id` on the given contract.
  Returns `{:ok, :completed}` when the last required signature is collected.
  """
  @spec sign(contract_id(), signatory_id()) :: sign_result()
  def sign(contract_id, signatory_id)
      when is_binary(contract_id) and is_binary(signatory_id) do
    with {:ok, contract} <- fetch_contract(contract_id),
         :ok <- check_contract_open(contract),
         {:ok, signatory} <- find_current_signatory(contract, signatory_id) do
      record_signature(contract, signatory)
    end
  end

  defp check_contract_open(%Contract{status: "finalised"}), do: {:error, :contract_finalised}
  defp check_contract_open(%Contract{}), do: :ok

  defp find_current_signatory(contract, signatory_id) do
    pending = Enum.reject(contract.signatories, & &1.signed_at)

    case pending do
      [] ->
        {:error, :already_signed}

      [current | _] when current.user_id == signatory_id ->
        {:ok, current}

      [_current | _] ->
        case Enum.find(contract.signatories, fn s -> s.user_id == signatory_id and s.signed_at end) do
          nil -> {:error, :not_your_turn}
          _already -> {:error, :already_signed}
        end
    end
  end

  defp record_signature(contract, signatory) do
    Repo.transaction(fn ->
      {:ok, _} =
        signatory
        |> Signatory.sign_changeset(%{signed_at: DateTime.utc_now()})
        |> Repo.update()

      remaining = Enum.count(contract.signatories, fn s -> s.id != signatory.id and is_nil(s.signed_at) end)

      if remaining == 0 do
        finalise_contract(contract)
        {:ok, :completed}
      else
        notify_next_signatory(contract)
        {:ok, :signed}
      end
    end)
    |> unwrap_transaction()
  end

  defp finalise_contract(contract) do
    contract
    |> Contract.status_changeset(%{status: "finalised", finalised_at: DateTime.utc_now()})
    |> Repo.update!()
  end

  defp notify_next_signatory(contract) do
    next = Enum.find(contract.signatories, fn s -> is_nil(s.signed_at) end)
    if next do
      Notify.dispatch(%{type: :signature_requested, recipient_id: next.user_id,
                        payload: %{contract_id: contract.id}})
    end
  end

  defp unwrap_transaction({:ok, result}), do: result
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
end
```
