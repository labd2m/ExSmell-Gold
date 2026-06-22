**File:** `example_good_1069.md`

```elixir
defmodule FeatureFlags do
  @moduledoc """
  Runtime feature flag evaluation engine supporting percentage rollouts,
  allowlist targeting, and environment overrides. Flag definitions are
  stored in ETS and reloaded periodically from the backing store.
  """

  alias FeatureFlags.{Store, Rule, Actor}

  @type flag_name :: atom()
  @type evaluation_context :: %{
          actor_id: String.t(),
          actor_type: :user | :organization | :device,
          attributes: map()
        }

  @spec enabled?(flag_name(), evaluation_context()) :: boolean()
  def enabled?(flag_name, %{actor_id: actor_id} = context)
      when is_atom(flag_name) and is_binary(actor_id) do
    case Store.fetch(flag_name) do
      {:ok, flag} -> evaluate(flag, context)
      :miss -> false
    end
  end

  @spec enable(flag_name()) :: :ok | {:error, term()}
  def enable(flag_name) when is_atom(flag_name) do
    Store.update(flag_name, %{globally_enabled: true})
  end

  @spec disable(flag_name()) :: :ok | {:error, term()}
  def disable(flag_name) when is_atom(flag_name) do
    Store.update(flag_name, %{globally_enabled: false})
  end

  @spec set_rollout(flag_name(), 0..100) :: :ok | {:error, term()}
  def set_rollout(flag_name, percentage)
      when is_atom(flag_name) and is_integer(percentage) and percentage in 0..100 do
    Store.update(flag_name, %{rollout_percentage: percentage})
  end

  @spec add_to_allowlist(flag_name(), String.t()) :: :ok | {:error, term()}
  def add_to_allowlist(flag_name, actor_id)
      when is_atom(flag_name) and is_binary(actor_id) do
    Store.add_to_allowlist(flag_name, actor_id)
  end

  defp evaluate(%{globally_enabled: true}, _context), do: true
  defp evaluate(%{globally_enabled: false}, _context), do: false

  defp evaluate(flag, %{actor_id: actor_id} = context) do
    in_allowlist?(flag, actor_id) or within_rollout?(flag, actor_id) or
      matches_rules?(flag, context)
  end

  defp in_allowlist?(%{allowlist: allowlist}, actor_id) do
    MapSet.member?(allowlist, actor_id)
  end

  defp within_rollout?(%{rollout_percentage: pct}, actor_id) when pct > 0 do
    bucket = Actor.stable_bucket(actor_id)
    bucket < pct
  end

  defp within_rollout?(%{rollout_percentage: 0}, _), do: false

  defp matches_rules?(%{rules: []}, _context), do: false

  defp matches_rules?(%{rules: rules}, context) do
    Enum.any?(rules, &Rule.matches?(&1, context))
  end
end

defmodule FeatureFlags.Actor do
  @moduledoc "Deterministic bucketing for stable percentage rollouts."

  @bucket_count 100

  @spec stable_bucket(String.t()) :: 0..99
  def stable_bucket(actor_id) when is_binary(actor_id) do
    :erlang.phash2(actor_id, @bucket_count)
  end
end

defmodule FeatureFlags.Rule do
  @moduledoc "Evaluates a single targeting rule against an evaluation context."

  @type t :: %__MODULE__{
          attribute: String.t(),
          operator: :eq | :in | :contains | :starts_with,
          value: term()
        }

  defstruct [:attribute, :operator, :value]

  @spec matches?(t(), map()) :: boolean()
  def matches?(%__MODULE__{attribute: attr, operator: :eq, value: expected}, context) do
    get_in(context, [:attributes, attr]) == expected
  end

  def matches?(%__MODULE__{attribute: attr, operator: :in, value: list}, context)
      when is_list(list) do
    actual = get_in(context, [:attributes, attr])
    actual in list
  end

  def matches?(%__MODULE__{attribute: attr, operator: :contains, value: substring}, context)
      when is_binary(substring) do
    case get_in(context, [:attributes, attr]) do
      value when is_binary(value) -> String.contains?(value, substring)
      _ -> false
    end
  end

  def matches?(%__MODULE__{attribute: attr, operator: :starts_with, value: prefix}, context)
      when is_binary(prefix) do
    case get_in(context, [:attributes, attr]) do
      value when is_binary(value) -> String.starts_with?(value, prefix)
      _ -> false
    end
  end
end
```
