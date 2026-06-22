```elixir
defmodule Onboarding.Workflow do
  @moduledoc """
  Orchestrates the multi-step user onboarding process as a pure state machine.
  Each step is represented by an atom; the transition map governs valid progressions.
  State persistence is the caller's responsibility; this module is stateless.
  """

  @type step ::
          :email_verification
          | :profile_completion
          | :payment_setup
          | :welcome_sent
          | :completed

  @type t :: %__MODULE__{
          user_id: String.t(),
          current_step: step(),
          completed_steps: [step()],
          metadata: map()
        }

  defstruct [:user_id, :current_step, completed_steps: [], metadata: %{}]

  @transitions %{
    email_verification: :profile_completion,
    profile_completion: :payment_setup,
    payment_setup: :welcome_sent,
    welcome_sent: :completed
  }

  @doc "Initializes a new onboarding workflow for the given user."
  @spec start(String.t()) :: t()
  def start(user_id) when is_binary(user_id) do
    %__MODULE__{user_id: user_id, current_step: :email_verification}
  end

  @doc "Advances the workflow to the next step, recording the completed step."
  @spec advance(t()) :: {:ok, t()} | {:error, :already_completed | :no_next_step}
  def advance(%__MODULE__{current_step: :completed}), do: {:error, :already_completed}
  def advance(%__MODULE__{current_step: step} = workflow) do
    case Map.get(@transitions, step) do
      nil -> {:error, :no_next_step}
      next_step ->
        updated = %{
          workflow
          | current_step: next_step,
            completed_steps: [step | workflow.completed_steps]
        }
        {:ok, updated}
    end
  end

  @doc "Returns true if the workflow has reached the completed state."
  @spec complete?(t()) :: boolean()
  def complete?(%__MODULE__{current_step: :completed}), do: true
  def complete?(%__MODULE__{}), do: false

  @doc "Returns an ordered list of remaining steps from the current position."
  @spec remaining_steps(t()) :: [step()]
  def remaining_steps(%__MODULE__{current_step: :completed}), do: []
  def remaining_steps(%__MODULE__{current_step: step}) do
    collect_remaining(step, @transitions, [])
  end

  defp collect_remaining(current, transitions, acc) do
    case Map.get(transitions, current) do
      nil -> Enum.reverse(acc)
      next -> collect_remaining(next, transitions, [next | acc])
    end
  end
end

defmodule Onboarding.WorkflowStore do
  @moduledoc """
  Persists and retrieves onboarding workflow state via the Repo.
  State is serialized into a JSONB column on the users table.
  """

  alias Onboarding.Workflow
  alias MyApp.Repo
  import Ecto.Query

  @doc "Loads the workflow state for a user, or starts a new one if absent."
  @spec load(String.t()) :: Workflow.t()
  def load(user_id) when is_binary(user_id) do
    case fetch_raw(user_id) do
      nil -> Workflow.start(user_id)
      raw -> deserialize(raw)
    end
  end

  @doc "Persists the current workflow state for the associated user."
  @spec save(Workflow.t()) :: :ok
  def save(%Workflow{user_id: uid} = workflow) do
    raw = serialize(workflow)
    Repo.update_all(
      from(u in "users", where: u.id == ^uid),
      set: [onboarding_state: raw]
    )
    :ok
  end

  defp fetch_raw(user_id) do
    from(u in "users", where: u.id == ^user_id, select: u.onboarding_state)
    |> Repo.one()
  end

  defp serialize(%Workflow{} = w) do
    %{
      "user_id" => w.user_id,
      "current_step" => Atom.to_string(w.current_step),
      "completed_steps" => Enum.map(w.completed_steps, &Atom.to_string/1)
    }
  end

  defp deserialize(%{"user_id" => uid, "current_step" => step, "completed_steps" => done}) do
    %Workflow{
      user_id: uid,
      current_step: String.to_existing_atom(step),
      completed_steps: Enum.map(done, &String.to_existing_atom/1)
    }
  end
end
```
