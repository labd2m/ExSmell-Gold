```elixir
defmodule Security.Firewall.RuleEvaluator do
  @moduledoc """
  Evaluates inbound network requests against an ordered firewall rule set.

  Rules are evaluated in priority order. The first matching rule determines
  the action applied to the request. Unmatched requests are subject to
  the configured default policy.
  """

  alias Security.Firewall.{Rule, Request, EvaluationLog}

  @type action :: :allow | :deny | :rate_limit | :challenge
  @type evaluation_result :: %{action: action(), matched_rule: Rule.t() | nil, reason: String.t()}

  @doc """
  Evaluates a request against an ordered list of firewall rules.

  Returns a result map describing the action to take, the matched rule (if any),
  and a human-readable reason string.
  """
  @spec evaluate(Request.t(), [Rule.t()], action()) :: evaluation_result()
  def evaluate(%Request{} = request, rules, default_action) when is_list(rules) do
    sorted = Enum.sort_by(rules, & &1.priority)

    result =
      Enum.reduce_while(sorted, :no_match, fn rule, :no_match ->
        if matches?(request, rule) do
          {:halt, {:matched, rule}}
        else
          {:cont, :no_match}
        end
      end)

    build_result(result, default_action)
  end

  @doc """
  Validates that a rule set has no duplicate priorities and all required fields.
  """
  @spec validate_rule_set([Rule.t()]) :: :ok | {:error, {:duplicate_priority, integer()}}
  def validate_rule_set(rules) do
    priorities = Enum.map(rules, & &1.priority)
    duplicates = priorities -- Enum.uniq(priorities)

    case duplicates do
      [] -> :ok
      [priority | _] -> {:error, {:duplicate_priority, priority}}
    end
  end

  defp matches?(%Request{} = req, %Rule{} = rule) do
    matches_ip?(req.source_ip, rule.ip_cidr) and
      matches_method?(req.method, rule.methods) and
      matches_path?(req.path, rule.path_pattern) and
      matches_headers?(req.headers, rule.required_headers)
  end

  defp matches_ip?(_ip, nil), do: true

  defp matches_ip?(ip, cidr) do
    case InetCidr.parse(cidr) do
      {:ok, parsed} -> InetCidr.contains?(parsed, ip)
      _ -> false
    end
  end

  defp matches_method?(_method, nil), do: true
  defp matches_method?(_method, []), do: true
  defp matches_method?(method, allowed), do: method in allowed

  defp matches_path?(_path, nil), do: true

  defp matches_path?(path, pattern) do
    Regex.match?(~r/#{pattern}/, path)
  end

  defp matches_headers?(_headers, nil), do: true
  defp matches_headers?(_headers, []), do: true

  defp matches_headers?(headers, required) do
    Enum.all?(required, fn {key, value} ->
      Map.get(headers, String.downcase(key)) == value
    end)
  end

  defp build_result({:matched, %Rule{action: action, description: desc} = rule}, _default) do
    EvaluationLog.record(action, rule.id, desc)
    %{action: action, matched_rule: rule, reason: desc}
  end

  defp build_result(:no_match, default_action) do
    EvaluationLog.record(default_action, nil, "default policy")
    %{action: default_action, matched_rule: nil, reason: "no matching rule; default policy applied"}
  end
end
```
