```elixir
defmodule Payments.Fraud.VelocityChecker do
  @moduledoc """
  Detects high-velocity transaction patterns indicative of fraud.
  Velocity rules are evaluated against a rolling time window of recent events
  per entity (card, account, device). All checks are stateless and pure;
  the event window is passed explicitly on each call.
  """

  @type entity_id :: String.t()
  @type event_type :: :charge | :declined | :chargeback | :address_change
  @type event :: %{
          entity_id: entity_id(),
          type: event_type(),
          amount_cents: non_neg_integer(),
          occurred_at: DateTime.t()
        }

  @type velocity_rule :: %{
          id: String.t(),
          event_types: [event_type()],
          window_seconds: pos_integer(),
          max_count: pos_integer() | nil,
          max_amount_cents: pos_integer() | nil
        }

  @type breach :: %{
          rule_id: String.t(),
          entity_id: entity_id(),
          event_count: non_neg_integer(),
          total_amount_cents: non_neg_integer()
        }

  @doc """
  Evaluates all `rules` against the events for `entity_id` in `event_window`.
  Returns `{:ok, breaches}` where breaches is a list of violated rules.
  """
  @spec check(entity_id(), [event()], [velocity_rule()]) ::
          {:ok, [breach()]} | {:error, String.t()}
  def check(entity_id, event_window, rules)
      when is_binary(entity_id) and is_list(event_window) and is_list(rules) do
    with :ok <- validate_rules(rules) do
      now = DateTime.utc_now()

      breaches =
        Enum.flat_map(rules, fn rule ->
          evaluate_rule(rule, entity_id, event_window, now)
        end)

      {:ok, breaches}
    end
  end

  @doc """
  Returns true when any rule is breached for `entity_id`.
  """
  @spec flagged?(entity_id(), [event()], [velocity_rule()]) :: boolean()
  def flagged?(entity_id, event_window, rules) do
    case check(entity_id, event_window, rules) do
      {:ok, [_ | _]} -> true
      {:ok, []} -> false
      {:error, _} -> false
    end
  end

  defp evaluate_rule(rule, entity_id, event_window, now) do
    cutoff = DateTime.add(now, -rule.window_seconds, :second)

    relevant =
      event_window
      |> Enum.filter(fn e ->
        e.entity_id == entity_id and
          e.type in rule.event_types and
          DateTime.compare(e.occurred_at, cutoff) != :lt
      end)

    count = length(relevant)
    total_amount = Enum.reduce(relevant, 0, fn e, acc -> acc + e.amount_cents end)
    count_breached = not is_nil(rule.max_count) and count > rule.max_count
    amount_breached = not is_nil(rule.max_amount_cents) and total_amount > rule.max_amount_cents

    if count_breached or amount_breached do
      [%{rule_id: rule.id, entity_id: entity_id, event_count: count, total_amount_cents: total_amount}]
    else
      []
    end
  end

  defp validate_rules(rules) do
    invalid = Enum.find(rules, fn r -> not valid_rule?(r) end)

    if is_nil(invalid) do
      :ok
    else
      {:error, "invalid velocity rule: #{inspect(invalid)}"}
    end
  end

  defp valid_rule?(%{id: id, event_types: types, window_seconds: ws, max_count: mc, max_amount_cents: ma})
       when is_binary(id) and id != "" and
              is_list(types) and types != [] and
              is_integer(ws) and ws > 0 and
              (is_nil(mc) or (is_integer(mc) and mc > 0)) and
              (is_nil(ma) or (is_integer(ma) and ma > 0)),
       do: true

  defp valid_rule?(_), do: false
end
```
