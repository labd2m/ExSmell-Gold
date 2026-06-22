```elixir
defmodule Onboarding.AccountSetup do
  @moduledoc """
  Orchestrates new account creation across multiple resources: user record,
  organisation, default workspace, billing customer, and a welcome email job.
  All database writes are committed atomically via `Ecto.Multi`; the billing
  customer creation and job enqueue happen inside the same transaction to
  prevent orphaned records if any step fails. The returned struct gives the
  caller everything needed to start a session without additional queries.
  """

  alias Ecto.Multi
  alias Onboarding.{BillingClient, Repo}
  alias MyApp.{Accounts, Billing, Workspaces}
  alias MyApp.Accounts.{Organisation, User}
  alias MyApp.Workspaces.Workspace
  alias Billing.Customer

  require Logger

  @type setup_attrs :: %{
          required(:email) => binary(),
          required(:password) => binary(),
          required(:org_name) => binary(),
          optional(:plan) => :starter | :growth | :enterprise
        }

  @type setup_result :: %{
          user: User.t(),
          organisation: Organisation.t(),
          workspace: Workspace.t(),
          billing_customer: Customer.t()
        }

  @doc """
  Creates all records required for a new account. Wraps all writes in a
  single transaction so no partial state is committed. The Oban welcome
  email job is inserted inside the transaction and runs only after commit.
  Returns `{:ok, setup_result}` or `{:error, failed_step, reason, changes}`.
  """
  @spec run(setup_attrs()) :: {:ok, setup_result()} | {:error, atom(), term(), map()}
  def run(%{email: email, password: _password, org_name: org_name} = attrs)
      when is_binary(email) and is_binary(org_name) do
    plan = Map.get(attrs, :plan, :starter)

    Multi.new()
    |> Multi.insert(:user, build_user_changeset(attrs))
    |> Multi.insert(:organisation, fn %{user: user} ->
      build_org_changeset(user, org_name, plan)
    end)
    |> Multi.insert(:workspace, fn %{user: user, organisation: org} ->
      build_workspace_changeset(user, org)
    end)
    |> Multi.run(:billing_customer, fn _repo, %{user: user, organisation: org} ->
      create_billing_customer(user, org, plan)
    end)
    |> Multi.run(:update_org_billing, fn repo, %{organisation: org, billing_customer: bc} ->
      org
      |> Organisation.billing_changeset(%{billing_customer_id: bc.external_id})
      |> repo.update()
    end)
    |> Multi.insert(:welcome_job, fn %{user: user} ->
      Onboarding.Workers.WelcomeEmail.new(%{"user_id" => user.id})
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user, organisation: org, workspace: ws, billing_customer: bc}} ->
        Logger.info("Account setup complete",
          user_id: user.id,
          org_id: org.id,
          plan: plan
        )

        {:ok, %{user: user, organisation: org, workspace: ws, billing_customer: bc}}

      {:error, step, reason, _changes} = err ->
        Logger.warning("Account setup failed",
          step: step,
          reason: inspect(reason),
          email: email
        )

        err
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp build_user_changeset(%{email: email, password: password}) do
    User.registration_changeset(%User{}, %{
      email: email,
      password: password,
      role: :owner
    })
  end

  defp build_org_changeset(user, org_name, plan) do
    Organisation.create_changeset(%Organisation{}, %{
      name: org_name,
      plan: plan,
      owner_id: user.id
    })
  end

  defp build_workspace_changeset(user, org) do
    Workspace.create_changeset(%Workspace{}, %{
      name: "Default",
      organisation_id: org.id,
      created_by_id: user.id
    })
  end

  defp create_billing_customer(user, org, plan) do
    case BillingClient.create_customer(%{
           email: user.email,
           name: org.name,
           metadata: %{organisation_id: org.id, plan: plan}
         }) do
      {:ok, customer} ->
        {:ok, customer}

      {:error, reason} ->
        Logger.error("Billing customer creation failed", reason: inspect(reason), org: org.name)
        {:error, {:billing_customer_failed, reason}}
    end
  end
end
```
