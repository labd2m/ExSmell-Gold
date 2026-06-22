```elixir
defmodule Agreements.ContractRenewalService do
  @moduledoc """
  Orchestrates the renewal workflow for expiring customer contracts.

  Renewal involves eligibility verification, pricing recalculation
  based on the current term and customer tier, creation of a renewal
  record, and dispatch of a confirmation notification. All database
  writes are wrapped in a single transaction to guarantee consistency.
  """

  alias Agreements.Repo
  alias Agreements.Contract
  alias Agreements.RenewalRecord
  alias Agreements.PricingCalculator
  alias Agreements.EligibilityChecker
  alias Agreements.NotificationDispatcher

  @type renewal_result ::
          {:ok, RenewalRecord.t()}
          | {:error, :not_eligible, String.t()}
          | {:error, :pricing_unavailable}
          | {:error, :persistence_failed}
          | {:error, :notification_failed}

  @doc """
  Attempts to renew the given contract for another term.

  Checks eligibility, computes the renewal price for the customer's
  tier, persists the renewal record, and dispatches a confirmation.
  Returns `{:ok, renewal}` on success or a structured error identifying
  which step failed.
  """
  @spec renew(Contract.t()) :: renewal_result()
  def renew(%Contract{} = contract) do
    with :ok <- verify_eligibility(contract),
         {:ok, renewal_price_cents} <- compute_renewal_price(contract),
         {:ok, renewal} <- persist_renewal(contract, renewal_price_cents),
         :ok <- send_confirmation(contract, renewal) do
      {:ok, renewal}
    end
  end

  @spec verify_eligibility(Contract.t()) ::
          :ok | {:error, :not_eligible, String.t()}
  defp verify_eligibility(contract) do
    case EligibilityChecker.check(contract) do
      {:eligible, _metadata} ->
        :ok

      {:ineligible, reason} ->
        {:error, :not_eligible, reason}
    end
  end

  @spec compute_renewal_price(Contract.t()) ::
          {:ok, pos_integer()} | {:error, :pricing_unavailable}
  defp compute_renewal_price(%Contract{customer_tier: tier, term_months: term}) do
    case PricingCalculator.renewal_price(tier, term) do
      {:ok, price_cents} when is_integer(price_cents) and price_cents > 0 ->
        {:ok, price_cents}

      {:error, _} ->
        {:error, :pricing_unavailable}
    end
  end

  @spec persist_renewal(Contract.t(), pos_integer()) ::
          {:ok, RenewalRecord.t()} | {:error, :persistence_failed}
  defp persist_renewal(%Contract{id: contract_id, term_months: term} = contract, price_cents) do
    now = DateTime.utc_now()

    attrs = %{
      contract_id: contract_id,
      previous_expiry: contract.expires_at,
      new_expiry: DateTime.add(contract.expires_at, term * 30 * 24 * 60 * 60, :second),
      renewal_price_cents: price_cents,
      renewed_at: now,
      status: :active
    }

    Repo.transaction(fn ->
      with {:ok, renewal} <- Repo.insert(RenewalRecord.changeset(%RenewalRecord{}, attrs)),
           {:ok, _contract} <- update_contract_expiry(contract, renewal.new_expiry) do
        renewal
      else
        {:error, _} -> Repo.rollback(:persistence_failed)
      end
    end)
    |> unwrap_transaction(:persistence_failed)
  end

  @spec update_contract_expiry(Contract.t(), DateTime.t()) ::
          {:ok, Contract.t()} | {:error, Ecto.Changeset.t()}
  defp update_contract_expiry(contract, new_expiry) do
    contract
    |> Contract.renewal_changeset(%{expires_at: new_expiry, status: :active})
    |> Repo.update()
  end

  @spec send_confirmation(Contract.t(), RenewalRecord.t()) ::
          :ok | {:error, :notification_failed}
  defp send_confirmation(%Contract{customer_id: customer_id}, renewal) do
    payload = %{
      customer_id: customer_id,
      renewal_id: renewal.id,
      new_expiry: renewal.new_expiry,
      price_cents: renewal.renewal_price_cents
    }

    case NotificationDispatcher.dispatch(:contract_renewed, payload) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :notification_failed}
    end
  end

  @spec unwrap_transaction({:ok, term()} | {:error, term()}, atom()) ::
          {:ok, term()} | {:error, atom()}
  defp unwrap_transaction({:ok, value}, _fallback), do: {:ok, value}
  defp unwrap_transaction({:error, reason}, _fallback) when is_atom(reason), do: {:error, reason}
  defp unwrap_transaction({:error, _}, fallback), do: {:error, fallback}
end
```
