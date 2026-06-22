```elixir
defmodule Platform.TenantOnboarding do
  @moduledoc """
  Orchestrates the multi-step provisioning workflow for new tenants.

  Each provisioning step is a discrete unit of work executed in sequence.
  Failures at any step trigger compensating cleanup for completed steps
  before propagating the error to the caller.
  """

  require Logger

  alias Platform.TenantOnboarding.{
    Step,
    StepResult,
    OnboardingRecord,
    Steps.ProvisionDatabase,
    Steps.SeedDefaultRoles,
    Steps.CreateAdminUser,
    Steps.SendWelcomeEmail
  }

  @steps [ProvisionDatabase, SeedDefaultRoles, CreateAdminUser, SendWelcomeEmail]

  @type tenant_params :: %{
          name: String.t(),
          subdomain: String.t(),
          admin_email: String.t(),
          plan: atom()
        }

  @doc """
  Runs the full tenant provisioning workflow synchronously.

  Returns `{:ok, record}` with the completed onboarding record on success,
  or `{:error, reason}` after rolling back any completed steps.
  """
  @spec provision(tenant_params()) :: {:ok, OnboardingRecord.t()} | {:error, String.t()}
  def provision(%{name: n, subdomain: s, admin_email: e, plan: p} = params)
      when is_binary(n) and is_binary(s) and is_binary(e) and is_atom(p) do
    Logger.info("starting tenant onboarding for #{s}")

    record = OnboardingRecord.new(params)
    run_steps(record, @steps, [])
  end

  def provision(_), do: {:error, "invalid tenant params"}

  # --- private helpers ---

  defp run_steps(record, [], _completed) do
    Logger.info("tenant #{record.subdomain} onboarded successfully")
    {:ok, OnboardingRecord.mark_complete(record)}
  end

  defp run_steps(record, [step | remaining], completed) do
    Logger.debug("running onboarding step #{inspect(step)} for #{record.subdomain}")

    case Step.run(step, record) do
      {:ok, updated_record} ->
        run_steps(updated_record, remaining, [step | completed])

      {:error, reason} ->
        Logger.error("onboarding step #{inspect(step)} failed: #{reason}")
        rollback(record, completed)
        {:error, "onboarding failed at #{inspect(step)}: #{reason}"}
    end
  end

  defp rollback(record, completed_steps) do
    Logger.warning("rolling back #{length(completed_steps)} onboarding steps for #{record.subdomain}")

    Enum.each(completed_steps, fn step ->
      case Step.compensate(step, record) do
        :ok ->
          Logger.debug("compensated step #{inspect(step)}")

        {:error, reason} ->
          Logger.error("compensation failed for #{inspect(step)}: #{reason}")
      end
    end)
  end
end

defmodule Platform.TenantOnboarding.Step do
  @moduledoc "Behaviour for provisioning steps that support forward execution and compensation."

  alias Platform.TenantOnboarding.OnboardingRecord

  @callback run(OnboardingRecord.t()) :: {:ok, OnboardingRecord.t()} | {:error, String.t()}
  @callback compensate(OnboardingRecord.t()) :: :ok | {:error, String.t()}

  @spec run(module(), OnboardingRecord.t()) :: {:ok, OnboardingRecord.t()} | {:error, String.t()}
  def run(step_module, record), do: step_module.run(record)

  @spec compensate(module(), OnboardingRecord.t()) :: :ok | {:error, String.t()}
  def compensate(step_module, record), do: step_module.compensate(record)
end

defmodule Platform.TenantOnboarding.OnboardingRecord do
  @moduledoc "Carries mutable provisioning context through the onboarding workflow."

  @enforce_keys [:tenant_name, :subdomain, :admin_email, :plan, :started_at]
  defstruct [
    :tenant_name, :subdomain, :admin_email, :plan,
    :started_at, :completed_at,
    tenant_id: nil, database_url: nil, admin_user_id: nil, status: :pending
  ]

  @type t :: %__MODULE__{}

  @spec new(map()) :: t()
  def new(%{name: name, subdomain: sub, admin_email: email, plan: plan}) do
    %__MODULE__{
      tenant_name: name,
      subdomain: sub,
      admin_email: email,
      plan: plan,
      started_at: DateTime.utc_now()
    }
  end

  @spec mark_complete(t()) :: t()
  def mark_complete(record), do: %{record | status: :complete, completed_at: DateTime.utc_now()}
end
```
