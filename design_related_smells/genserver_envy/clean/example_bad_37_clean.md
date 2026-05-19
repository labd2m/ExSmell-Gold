```elixir
defmodule MyApp.ContractNegotiationAgent do
  @moduledoc """
  Manages supplier contract negotiation workflows including proposal tracking,
  counter-offers, legal review gating, and finalisation.
  """

  use Agent

  alias MyApp.{Repo, Mailer, AuditLog, DocumentService, LegalReviewQueue}
  alias MyApp.Contracts.{Negotiation, Proposal, FinalContract}

  @max_rounds 10

  def start_link(_opts) do
    negotiations = Repo.all(Negotiation) |> Enum.into(%{}, &{&1.id, &1})
    Agent.start_link(fn -> %{negotiations: negotiations} end, name: __MODULE__)
  end

  def get_negotiation(id) do
    Agent.get(__MODULE__, fn state -> Map.get(state.negotiations, id) end)
  end

  def list_active do
    Agent.get(__MODULE__, fn state ->
      state.negotiations |> Map.values() |> Enum.filter(&(&1.status == :in_progress))
    end)
  end

  def submit_proposal(supplier_id, terms, submitted_by) do
    Agent.get_and_update(__MODULE__, fn state ->
      case validate_terms(terms) do
        {:error, reasons} ->
          {{:error, {:invalid_terms, reasons}}, state}

        :ok ->
          proposal = %Proposal{
            id: Ecto.UUID.generate(),
            round: 1,
            terms: terms,
            submitted_by: submitted_by,
            submitted_at: DateTime.utc_now()
          }

          negotiation = %Negotiation{
            id: Ecto.UUID.generate(),
            supplier_id: supplier_id,
            proposals: [proposal],
            current_round: 1,
            status: :in_progress,
            started_at: DateTime.utc_now()
          }

          case Repo.insert(negotiation) do
            {:ok, saved} ->
              LegalReviewQueue.enqueue(saved.id, proposal)
              Mailer.notify_supplier_proposal_received(supplier_id, saved.id)
              AuditLog.record(:negotiation_started, %{id: saved.id, by: submitted_by})
              new_state = put_in(state, [:negotiations, saved.id], saved)
              {{:ok, saved}, new_state}

            {:error, reason} ->
              {{:error, reason}, state}
          end
      end
    end)
  end

  def counter_propose(negotiation_id, counter_terms, proposed_by) do
    Agent.get_and_update(__MODULE__, fn state ->
      with {:ok, negotiation} <- Map.fetch(state.negotiations, negotiation_id),
           :in_progress <- negotiation.status,
           false <- negotiation.current_round >= @max_rounds do
        case validate_terms(counter_terms) do
          {:error, reasons} ->
            {{:error, {:invalid_terms, reasons}}, state}

          :ok ->
            next_round = negotiation.current_round + 1

            counter = %Proposal{
              id: Ecto.UUID.generate(),
              round: next_round,
              terms: counter_terms,
              submitted_by: proposed_by,
              submitted_at: DateTime.utc_now()
            }

            updated_negotiation = %{
              negotiation
              | proposals: [counter | negotiation.proposals],
                current_round: next_round
            }

            Repo.update!(updated_negotiation)
            LegalReviewQueue.enqueue(negotiation_id, counter)
            Mailer.notify_counter_proposal(negotiation.supplier_id, negotiation_id, next_round)
            AuditLog.record(:counter_proposed, %{id: negotiation_id, round: next_round})

            new_state = put_in(state, [:negotiations, negotiation_id], updated_negotiation)
            {{:ok, updated_negotiation}, new_state}
        end
      else
        :error -> {{:error, :negotiation_not_found}, state}
        status when is_atom(status) -> {{:error, {:wrong_status, status}}, state}
        true -> {{:error, :max_rounds_reached}, state}
      end
    end)
  end

  def finalise(negotiation_id, finalised_by) do
    Agent.get_and_update(__MODULE__, fn state ->
      with {:ok, negotiation} <- Map.fetch(state.negotiations, negotiation_id),
           :in_progress <- negotiation.status do
        latest_proposal = hd(negotiation.proposals)

        case DocumentService.generate_contract(negotiation, latest_proposal) do
          {:ok, doc_ref} ->
            final = %FinalContract{
              id: Ecto.UUID.generate(),
              negotiation_id: negotiation_id,
              supplier_id: negotiation.supplier_id,
              terms: latest_proposal.terms,
              document_ref: doc_ref,
              finalised_by: finalised_by,
              finalised_at: DateTime.utc_now()
            }

            Repo.insert!(final)
            updated_negotiation = %{negotiation | status: :finalised}
            Repo.update!(updated_negotiation)
            Mailer.notify_contract_finalised(negotiation.supplier_id, doc_ref)
            AuditLog.record(:contract_finalised, %{id: negotiation_id, by: finalised_by})

            new_state = put_in(state, [:negotiations, negotiation_id], updated_negotiation)
            {{:ok, final}, new_state}

          {:error, reason} ->
            {{:error, {:document_generation_failed, reason}}, state}
        end
      else
        :error -> {{:error, :not_found}, state}
        status -> {{:error, {:wrong_status, status}}, state}
      end
    end)
  end

  defp validate_terms(terms) do
    required = [:price_per_unit, :delivery_days, :payment_terms, :jurisdiction]
    missing = Enum.reject(required, &Map.has_key?(terms, &1))

    case missing do
      [] -> :ok
      fields -> {:error, Enum.map(fields, &{&1, :required})}
    end
  end
end
```
