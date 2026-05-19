```elixir
defmodule FeatureFlagAgent do
  @moduledoc "Shared Agent for runtime feature flag state."

  def start_link(_opts \\ []) do
    Agent.start_link(
      fn ->
        %{
          flags: %{},
          change_log: []
        }
      end,
      name: __MODULE__
    )
  end

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :permanent}
  end
end

defmodule FeatureFlagWriter do
  @moduledoc "Creates and updates feature flag definitions."

  require Logger

  @valid_strategies [:all_users, :no_users, :percentage, :allowlist, :denylist]

  def upsert(agent, %{name: name, strategy: strategy} = attrs) when strategy in @valid_strategies do
    existing = Agent.get(agent, fn state -> Map.get(state.flags, name) end)

    flag = %{
      name: name,
      strategy: strategy,
      percentage: Map.get(attrs, :percentage, 0),
      allowlist: Map.get(attrs, :allowlist, []),
      denylist: Map.get(attrs, :denylist, []),
      description: Map.get(attrs, :description, ""),
      enabled: Map.get(attrs, :enabled, true),
      created_at: (existing && existing.created_at) || DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    Agent.update(agent, fn state ->
      change = %{
        flag: name,
        action: if(is_nil(existing), do: :created, else: :updated),
        by: Map.get(attrs, :updated_by, :system),
        at: DateTime.utc_now()
      }

      %{
        state
        | flags: Map.put(state.flags, name, flag),
          change_log: [change | state.change_log]
      }
    end)

    Logger.info("#{if existing, do: "Updated", else: "Created"} flag #{name} with strategy #{strategy}")
    :ok
  end

  def upsert(_agent, %{strategy: s}), do: {:error, {:unknown_strategy, s}}
  def upsert(_agent, _), do: {:error, :missing_name_or_strategy}
end
defmodule FeatureFlagReader do
  @moduledoc "Evaluates feature flags for a given user context."

  def enabled_for?(agent, flag_name, %{user_id: user_id} = _context) do
    flag = Agent.get(agent, fn state -> Map.get(state.flags, flag_name) end)

    case flag do
      nil -> false
      %{enabled: false} -> false
      %{strategy: :all_users} -> true
      %{strategy: :no_users} -> false

      %{strategy: :percentage, percentage: pct} ->
        bucket = :erlang.phash2(user_id, 100)
        bucket < pct

      %{strategy: :allowlist, allowlist: list} ->
        user_id in list

      %{strategy: :denylist, denylist: list} ->
        user_id not in list

      _ -> false
    end
  end

  def flag_details(agent, flag_name) do
    Agent.get(agent, fn state -> Map.get(state.flags, flag_name) end)
  end

  def all_flags(agent) do
    Agent.get(agent, fn state -> Map.values(state.flags) end)
  end
end
defmodule FeatureFlagRollout do
  @moduledoc "Manages gradual percentage-based rollout progression."

  require Logger

  def set_percentage(agent, flag_name, new_pct) when new_pct >= 0 and new_pct <= 100 do
    case Agent.get(agent, fn state -> Map.get(state.flags, flag_name) end) do
      nil ->
        {:error, :flag_not_found}

      %{strategy: strategy} when strategy != :percentage ->
        {:error, {:wrong_strategy, strategy}}

      flag ->
        Agent.update(agent, fn state ->
          updated = %{flag | percentage: new_pct, updated_at: DateTime.utc_now()}

          change = %{
            flag: flag_name,
            action: :percentage_change,
            from: flag.percentage,
            to: new_pct,
            at: DateTime.utc_now()
          }

          %{
            state
            | flags: Map.put(state.flags, flag_name, updated),
              change_log: [change | state.change_log]
          }
        end)

        Logger.info("Rolled out #{flag_name} to #{new_pct}% of users")
        :ok
    end
  end

  def set_percentage(_agent, _name, pct), do: {:error, {:invalid_percentage, pct}}
end
defmodule FeatureFlagAuditor do
  @moduledoc "Provides audit trail and change history for feature flags."

  def change_log(agent) do
    Agent.get(agent, fn state ->
      Enum.sort_by(state.change_log, & &1.at, {:desc, DateTime})
    end)
  end

  def changes_for_flag(agent, flag_name) do
    Agent.get(agent, fn state ->
      state.change_log
      |> Enum.filter(&(&1.flag == flag_name))
      |> Enum.sort_by(& &1.at, {:desc, DateTime})
    end)
  end

  def recent_changes(agent, n \\ 20) do
    Agent.get(agent, fn state ->
      state.change_log
      |> Enum.sort_by(& &1.at, {:desc, DateTime})
      |> Enum.take(n)
    end)
  end

  def flags_changed_by(agent, actor) do
    Agent.get(agent, fn state ->
      state.change_log
      |> Enum.filter(&(&1[:by] == actor))
      |> Enum.map(& &1.flag)
      |> Enum.uniq()
    end)
  end
end
```
