```elixir
defmodule MyApp.OnboardingAgent do
  @moduledoc """
  Manages employee onboarding workflows including step tracking,
  provisioning coordination, and completion notifications.
  """

  use Agent

  alias MyApp.{Mailer, HRSystem, ITProvisioner, AuditLog, Repo}
  alias MyApp.Onboarding.{Workflow, Step, StepResult}

  @onboarding_steps [
    :collect_personal_info,
    :verify_identity,
    :provision_accounts,
    :assign_equipment,
    :complete_hr_forms,
    :security_training,
    :manager_introduction
  ]

  def start_link(_opts) do
    Agent.start_link(fn -> %{workflows: %{}} end, name: __MODULE__)
  end

  def get_workflow(employee_id) do
    Agent.get(__MODULE__, fn state -> Map.get(state.workflows, employee_id) end)
  end

  def start_onboarding(employee_id, manager_id) do
    Agent.get_and_update(__MODULE__, fn state ->
      if Map.has_key?(state.workflows, employee_id) do
        {{:error, :already_onboarding}, state}
      else
        workflow = %Workflow{
          id: Ecto.UUID.generate(),
          employee_id: employee_id,
          manager_id: manager_id,
          current_step: hd(@onboarding_steps),
          completed_steps: [],
          step_results: %{},
          started_at: DateTime.utc_now(),
          status: :in_progress
        }

        case Repo.insert(workflow) do
          {:ok, saved} ->
            Mailer.deliver_onboarding_welcome(employee_id, manager_id)
            AuditLog.record(:onboarding_started, %{employee_id: employee_id})
            new_state = put_in(state, [:workflows, employee_id], saved)
            {{:ok, saved}, new_state}

          {:error, reason} ->
            {{:error, reason}, state}
        end
      end
    end)
  end

  def complete_step(employee_id, step, result_data) do
    Agent.get_and_update(__MODULE__, fn state ->
      with {:ok, workflow} <- Map.fetch(state.workflows, employee_id),
           true <- workflow.current_step == step,
           :in_progress <- workflow.status do
        step_result = %StepResult{
          step: step,
          data: result_data,
          completed_at: DateTime.utc_now(),
          completed_by: employee_id
        }

        side_effect_result = run_step_side_effects(step, employee_id, result_data)

        case side_effect_result do
          {:error, reason} ->
            {{:error, {:step_side_effect_failed, reason}}, state}

          :ok ->
            completed = [step | workflow.completed_steps]
            step_results = Map.put(workflow.step_results, step, step_result)
            remaining = @onboarding_steps -- completed

            {next_step, new_status} =
              case remaining do
                [] -> {nil, :completed}
                [next | _] -> {next, :in_progress}
              end

            updated_workflow = %{
              workflow
              | current_step: next_step,
                completed_steps: completed,
                step_results: step_results,
                status: new_status
            }

            Repo.update!(updated_workflow)
            AuditLog.record(:onboarding_step_completed, %{employee_id: employee_id, step: step})

            if new_status == :completed do
              Mailer.deliver_onboarding_complete(employee_id, workflow.manager_id)
              HRSystem.mark_onboarding_complete(employee_id)
            else
              Mailer.deliver_next_step_prompt(employee_id, next_step)
            end

            new_state = put_in(state, [:workflows, employee_id], updated_workflow)
            {{:ok, updated_workflow}, new_state}
        end
      else
        :error -> {{:error, :workflow_not_found}, state}
        false -> {{:error, :wrong_step}, state}
        status -> {{:error, {:invalid_workflow_status, status}}, state}
      end
    end)
  end

  def advance_step(employee_id, admin_id) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.fetch(state.workflows, employee_id) do
        :error ->
          {{:error, :not_found}, state}

        {:ok, workflow} ->
          remaining =
            @onboarding_steps
            |> Enum.drop_while(&(&1 != workflow.current_step))
            |> tl()

          case remaining do
            [] ->
              updated = %{workflow | status: :completed}
              Repo.update!(updated)
              AuditLog.record(:onboarding_force_advanced, %{by: admin_id, employee: employee_id})
              {{:ok, :completed}, put_in(state, [:workflows, employee_id], updated)}

            [next | _] ->
              updated = %{workflow | current_step: next}
              Repo.update!(updated)
              AuditLog.record(:onboarding_force_advanced, %{by: admin_id, to: next})
              {{:ok, next}, put_in(state, [:workflows, employee_id], updated)}
          end
      end
    end)
  end

  defp run_step_side_effects(:provision_accounts, employee_id, _data) do
    ITProvisioner.provision(employee_id)
  end

  defp run_step_side_effects(:verify_identity, employee_id, data) do
    HRSystem.submit_identity_verification(employee_id, data)
  end

  defp run_step_side_effects(_step, _employee_id, _data), do: :ok

  def list_in_progress do
    Agent.get(__MODULE__, fn state ->
      state.workflows
      |> Map.values()
      |> Enum.filter(&(&1.status == :in_progress))
    end)
  end
end
```
