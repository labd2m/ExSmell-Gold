# Annotated Example — GenServer Envy

- **Smell name:** GenServer Envy
- **Expected smell location:** `FeatureFlagAgent` — `Agent` executing flag evaluation and rollout logic
- **Affected function(s):** `evaluate/3`, `rollout/3`, `archive_flag/2`
- **Short explanation:** Feature flag evaluation involves percentage rollouts, user segment matching, and audit logging — complex business logic that should be in a `GenServer`, not an `Agent`.

```elixir
defmodule MyApp.FeatureFlagAgent do
  @moduledoc """
  Manages feature flags with percentage-based rollouts, segment targeting,
  and flag lifecycle management (creation, rollout, archival).
  """

  use Agent

  alias MyApp.{Repo, AuditLog, SegmentMatcher}
  alias MyApp.Flags.{Flag, Evaluation}

  def start_link(_opts) do
    flags = Repo.all(Flag) |> Enum.into(%{}, &{&1.key, &1})
    Agent.start_link(fn -> %{flags: flags, evaluations: %{}} end, name: __MODULE__)
  end

  def list_flags do
    Agent.get(__MODULE__, & &1.flags)
  end

  def get_flag(key) do
    Agent.get(__MODULE__, fn state -> Map.get(state.flags, key) end)
  end

  # VALIDATION: SMELL START - GenServer Envy
  # VALIDATION: This is a smell because the Agent is used to execute feature flag
  # evaluation logic that includes percentage-based rollout calculations, user
  # segment matching, evaluation logging, and flag lifecycle transitions (rollout,
  # archival). This multi-step, side-effectful orchestration exceeds the simple
  # state-sharing role intended for an Agent and should be implemented as a GenServer.

  def create_flag(key, description, owner) do
    Agent.get_and_update(__MODULE__, fn state ->
      if Map.has_key?(state.flags, key) do
        {{:error, :already_exists}, state}
      else
        flag = %Flag{
          key: key,
          description: description,
          owner: owner,
          enabled: false,
          rollout_percent: 0,
          segments: [],
          created_at: DateTime.utc_now(),
          status: :draft
        }

        case Repo.insert(flag) do
          {:ok, saved} ->
            AuditLog.record(:flag_created, %{key: key, owner: owner})
            {{:ok, saved}, put_in(state, [:flags, key], saved)}

          {:error, reason} ->
            {{:error, reason}, state}
        end
      end
    end)
  end

  def evaluate(flag_key, user_id, user_attrs) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.fetch(state.flags, flag_key) do
        :error ->
          {{:ok, false}, state}

        {:ok, %Flag{enabled: false}} ->
          {{:ok, false}, state}

        {:ok, %Flag{status: :archived}} ->
          {{:ok, false}, state}

        {:ok, flag} ->
          in_segment? = SegmentMatcher.matches?(user_attrs, flag.segments)

          in_rollout? =
            if flag.rollout_percent >= 100 do
              true
            else
              hash = :erlang.phash2({flag_key, user_id}, 100)
              hash < flag.rollout_percent
            end

          result = in_segment? or in_rollout?

          eval = %Evaluation{
            flag_key: flag_key,
            user_id: user_id,
            result: result,
            evaluated_at: DateTime.utc_now()
          }

          new_evals = Map.update(state.evaluations, flag_key, [eval], &[eval | Enum.take(&1, 99)])
          {{:ok, result}, %{state | evaluations: new_evals}}
      end
    end)
  end

  def rollout(flag_key, percent, updated_by) when percent in 0..100 do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.fetch(state.flags, flag_key) do
        :error ->
          {{:error, :not_found}, state}

        {:ok, flag} ->
          updated = %{flag | rollout_percent: percent, enabled: percent > 0, status: :active}

          case Repo.update(updated) do
            {:ok, saved} ->
              AuditLog.record(:flag_rollout, %{key: flag_key, percent: percent, by: updated_by})
              {{:ok, saved}, put_in(state, [:flags, flag_key], saved)}

            {:error, reason} ->
              {{:error, reason}, state}
          end
      end
    end)
  end

  def archive_flag(flag_key, archived_by) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.fetch(state.flags, flag_key) do
        :error ->
          {{:error, :not_found}, state}

        {:ok, flag} ->
          archived = %{flag | enabled: false, rollout_percent: 0, status: :archived}

          case Repo.update(archived) do
            {:ok, saved} ->
              AuditLog.record(:flag_archived, %{key: flag_key, by: archived_by})
              {{:ok, saved}, put_in(state, [:flags, flag_key], saved)}

            {:error, reason} ->
              {{:error, reason}, state}
          end
      end
    end)
  end

  # VALIDATION: SMELL END

  def recent_evaluations(flag_key, limit \\ 10) do
    Agent.get(__MODULE__, fn state ->
      state.evaluations
      |> Map.get(flag_key, [])
      |> Enum.take(limit)
    end)
  end
end
```
