```elixir
defmodule MyApp.ContractLifecycle do
  @moduledoc """
  Manages the full contract lifecycle: drafting, electronic signature workflow,
  billing schedule generation, and compliance expiry monitoring.
  """

  alias MyApp.Repo
  alias MyApp.Schemas.{Contract, ContractSignature, BillingMilestone}
  alias MyApp.Integrations.{DocuSign, Mailer}
  import Ecto.Query



  @doc """
  Creates a new contract in draft status between two parties.
  """
  def draft_contract(client_id, attrs) do
    %Contract{}
    |> Contract.changeset(
      Map.merge(attrs, %{
        client_id: client_id,
        status: :draft,
        contract_number: generate_contract_number(),
        drafted_at: DateTime.utc_now()
      })
    )
    |> Repo.insert()
  end

  @doc """
  Sends a draft contract to the specified signatories via DocuSign.
  """
  def send_for_signature(%Contract{status: :draft} = contract, signatories) do
    client = MyApp.Clients.get!(contract.client_id)

    envelope_id =
      DocuSign.create_envelope(%{
        document_url: contract.document_url,
        signatories: Enum.map(signatories, &%{email: &1.email, name: &1.name}),
        subject: "Please sign: #{contract.title}"
      })

    contract
    |> Contract.changeset(%{
      status: :awaiting_signatures,
      docusign_envelope_id: envelope_id,
      sent_for_signature_at: DateTime.utc_now()
    })
    |> Repo.update()
  end

  def send_for_signature(%Contract{}, _), do: {:error, :only_draft_can_be_sent}

  @doc """
  Records a completed signature event from a DocuSign webhook callback.
  """
  def record_signature(contract_id, signatory_email, signed_at) do
    contract = Repo.get!(Contract, contract_id)

    %ContractSignature{}
    |> ContractSignature.changeset(%{
      contract_id: contract_id,
      signatory_email: signatory_email,
      signed_at: signed_at
    })
    |> Repo.insert!()

    all_signed = all_parties_signed?(contract)

    if all_signed do
      activate_contract(contract)
    end

    {:ok, %{all_signed: all_signed}}
  end

  @doc """
  Marks a fully-signed contract as active and triggers billing setup.
  """
  def activate_contract(%Contract{} = contract) do
    contract
    |> Contract.changeset(%{status: :active, activated_at: DateTime.utc_now()})
    |> Repo.update()
    |> case do
      {:ok, activated} = result ->
        compute_billing_schedule(activated)
        result

      error ->
        error
    end
  end

  defp all_parties_signed?(contract) do
    sig_count = Repo.one(from s in ContractSignature, where: s.contract_id == ^contract.id, select: count(s.id))
    sig_count >= (contract.required_signatures || 2)
  end

  defp generate_contract_number do
    "CTR-#{Date.utc_today().year}-#{:rand.uniform(999_999) |> Integer.to_string() |> String.pad_leading(6, "0")}"
  end


  @doc """
  Generates billing milestones based on the contract's payment terms.
  """
  def compute_billing_schedule(%Contract{} = contract) do
    total_cents = contract.total_value_cents
    interval_months = contract.billing_interval_months || 1
    duration_months = contract.duration_months || 12
    milestone_count = div(duration_months, interval_months)

    Repo.transaction(fn ->
      Enum.each(0..(milestone_count - 1), fn i ->
        due_date = Date.add(Date.utc_today(), i * interval_months * 30)
        amount = if i == milestone_count - 1,
          do: total_cents - round(total_cents / milestone_count) * (milestone_count - 1),
          else: round(total_cents / milestone_count)

        %BillingMilestone{}
        |> BillingMilestone.changeset(%{
          contract_id: contract.id,
          due_date: due_date,
          amount_cents: amount,
          status: :pending,
          sequence: i + 1
        })
        |> Repo.insert!()
      end)
    end)
  end


  @doc """
  Checks whether a contract's compliance certifications are approaching expiry.
  Returns a list of warnings for documents expiring within 30 days.
  """
  def check_compliance_expiry(%Contract{} = contract) do
    today = Date.utc_today()
    warning_threshold = Date.add(today, 30)

    warnings =
      (contract.compliance_documents || [])
      |> Enum.filter(fn doc ->
        expiry = Date.from_iso8601!(doc["expiry_date"])
        Date.compare(expiry, warning_threshold) in [:lt, :eq]
      end)
      |> Enum.map(fn doc ->
        expiry = Date.from_iso8601!(doc["expiry_date"])
        days_left = Date.diff(expiry, today)
        %{document: doc["name"], expiry: expiry, days_remaining: days_left}
      end)

    if warnings != [] do
      client = MyApp.Clients.get!(contract.client_id)

      Mailer.send(%{
        to: client.email,
        subject: "Compliance documents expiring on contract #{contract.contract_number}",
        text_body: "The following documents are expiring soon: #{Enum.map_join(warnings, ", ", & &1.document)}"
      })
    end

    {:ok, warnings}
  end

end
```
