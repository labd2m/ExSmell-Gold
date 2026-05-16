# Code Smell: Alternative Return Types

## Metadata

- **Smell name:** Alternative Return Types
- **Expected smell location:** `Onboarding.StepRunner.run/2`
- **Affected function(s):** `run/2`
- **Short explanation:** The `:output` option makes the function return a plain `:ok | {:error, reason}`, a `{status, completed_steps}` tuple, or a `%OnboardingResult{}` struct. Each type encodes a different level of detail about the same operation, and callers must know which output mode was used to consume the result.

---

```elixir
defmodule MyApp.Onboarding.StepRunner do
  @moduledoc """
  Executes the onboarding workflow for new user accounts. Each step
  (profile setup, email verification, payment method, team invite)
  runs in sequence with rollback support on failure.
  """

  alias MyApp.Onboarding.Step
  alias MyApp.Onboarding.Rollback
  alias MyApp.Onboarding.ProgressStore
  alias MyApp.Accounts.User

  defstruct [
    :user_id, :completed_steps, :failed_step,
    :started_at, :finished_at, :status,
    :errors
  ]

  @default_steps [
    :create_profile,
    :send_verification_email,
    :setup_default_preferences,
    :initialize_billing_record,
    :send_welcome_notification
  ]

  def steps_for(plan) do
    case plan do
      :team -> @default_steps ++ [:create_team_workspace, :send_team_invites]
      :enterprise -> @default_steps ++ [:provision_sso, :assign_account_manager]
      _ -> @default_steps
    end
  end

  # VALIDATION: SMELL START - Alternative Return Types
  # VALIDATION: This is a smell because opts[:output] changes the return type
  # completely: :simple returns :ok or {:error, reason} (a plain atom/tuple),
  # :progress returns {status_atom, [completed_step_atoms]} (a 2-element tuple),
  # and :report returns a %OnboardingResult{} struct with full detail.
  # Each type is consumed differently by the callers (e.g. controller actions,
  # background jobs, audit dashboards), but the function merges all three
  # into one with an option, making the return unpredictable from the signature.
  def run(user_id, opts \\ []) when is_list(opts) do
    output = Keyword.get(opts, :output, :simple)
    steps = Keyword.get(opts, :steps, @default_steps)
    rollback_on_failure = Keyword.get(opts, :rollback_on_failure, true)

    started_at = DateTime.utc_now()
    completed = []
    errors = []

    {final_status, completed_steps, final_errors} =
      Enum.reduce_while(steps, {:ok, completed, errors}, fn step, {_, done, errs} ->
        case Step.execute(step, user_id) do
          :ok ->
            ProgressStore.mark_complete(user_id, step)
            {:cont, {:ok, done ++ [step], errs}}

          {:error, reason} ->
            if rollback_on_failure do
              Rollback.run(done, user_id)
            end

            {:halt, {:error, done, errs ++ [{step, reason}]}}
        end
      end)

    finished_at = DateTime.utc_now()

    case output do
      :simple ->
        case final_status do
          :ok -> :ok
          :error -> {:error, final_errors}
        end

      :progress ->
        {final_status, completed_steps}

      :report ->
        %__MODULE__{
          user_id: user_id,
          completed_steps: completed_steps,
          failed_step: if(final_status == :error, do: List.last(steps -- completed_steps)),
          started_at: started_at,
          finished_at: finished_at,
          status: final_status,
          errors: final_errors
        }
    end
  end
  # VALIDATION: SMELL END

  def resume(user_id, opts \\ []) do
    already_done = ProgressStore.completed_steps(user_id)
    remaining = Enum.reject(@default_steps, &(&1 in already_done))
    run(user_id, Keyword.put(opts, :steps, remaining))
  end

  def completed?(user_id) do
    done = ProgressStore.completed_steps(user_id)
    Enum.all?(@default_steps, &(&1 in done))
  end

  def progress_summary(user_id) do
    done = ProgressStore.completed_steps(user_id)
    total = length(@default_steps)
    completed_count = length(done)

    %{
      user_id: user_id,
      completed: completed_count,
      total: total,
      percent: Float.round(completed_count / total * 100, 1),
      remaining: @default_steps -- done
    }
  end
end
```
