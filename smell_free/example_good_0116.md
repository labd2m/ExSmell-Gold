```elixir
defmodule Workflow.ApprovalChain do
  @moduledoc """
  Models a multi-step sequential approval chain as a supervised GenServer
  aggregate. The chain advances through steps as approvers act. Each
  transition is recorded immutably in the history list. Forbidden
  transitions return typed error tuples rather than raising.
  """

  use GenServer

  @type approver_id :: String.t()
  @type step :: %{approver_id: approver_id(), label: String.t()}
  @type step_status :: :pending | :approved | :rejected
  @type history_entry :: %{
          step_index: non_neg_integer(),
          approver_id: approver_id(),
          status: step_status(),
          note: String.t() | nil,
          acted_at: DateTime.t()
        }
  @type chain_status :: :in_progress | :approved | :rejected
  @type state :: %{
          chain_id: String.t(),
          steps: [step()],
          current_index: non_neg_integer(),
          history: [history_entry()],
          chain_status: chain_status()
        }

  @doc "Starts an approval chain GenServer registered via a Registry."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    chain_id = Keyword.fetch!(opts, :chain_id)
    GenServer.start_link(__MODULE__, opts, name: via(chain_id))
  end

  @doc "Approves the current step. Returns an error when already concluded."
  @spec approve(String.t(), approver_id(), String.t() | nil) ::
          :ok | {:error, :chain_concluded | :wrong_approver}
  def approve(chain_id, approver_id, note \\ nil) do
    GenServer.call(via(chain_id), {:advance, approver_id, :approved, note})
  end

  @doc "Rejects the current step, concluding the entire chain."
  @spec reject(String.t(), approver_id(), String.t() | nil) ::
          :ok | {:error, :chain_concluded | :wrong_approver}
  def reject(chain_id, approver_id, note \\ nil) do
    GenServer.call(via(chain_id), {:advance, approver_id, :rejected, note})
  end

  @doc "Returns the current chain state snapshot."
  @spec status(String.t()) :: state()
  def status(chain_id), do: GenServer.call(via(chain_id), :status)

  @impl GenServer
  def init(opts) do
    {:ok,
     %{
       chain_id: Keyword.fetch!(opts, :chain_id),
       steps: Keyword.fetch!(opts, :steps),
       current_index: 0,
       history: [],
       chain_status: :in_progress
     }}
  end

  @impl GenServer
  def handle_call({:advance, _aid, _status, _note}, _from, %{chain_status: s} = state)
      when s != :in_progress do
    {:reply, {:error, :chain_concluded}, state}
  end

  def handle_call({:advance, approver_id, step_status, note}, _from, state) do
    current_step = Enum.at(state.steps, state.current_index)

    if current_step.approver_id != approver_id do
      {:reply, {:error, :wrong_approver}, state}
    else
      entry = build_history_entry(state.current_index, approver_id, step_status, note)
      new_state = apply_transition(state, step_status, entry)
      {:reply, :ok, new_state}
    end
  end

  def handle_call(:status, _from, state), do: {:reply, state, state}

  defp apply_transition(%{current_index: idx, steps: steps} = state, :approved, entry) do
    next_index = idx + 1
    new_chain_status = if next_index >= length(steps), do: :approved, else: :in_progress

    %{state | current_index: next_index, history: [entry | state.history],
              chain_status: new_chain_status}
  end

  defp apply_transition(state, :rejected, entry) do
    %{state | history: [entry | state.history], chain_status: :rejected}
  end

  defp build_history_entry(index, approver_id, step_status, note) do
    %{step_index: index, approver_id: approver_id, status: step_status,
      note: note, acted_at: DateTime.utc_now()}
  end

  defp via(chain_id), do: {:via, Registry, {Workflow.Registry, chain_id}}
end
```
