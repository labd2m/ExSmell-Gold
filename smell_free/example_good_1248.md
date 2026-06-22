```elixir
defmodule Scm.Repositories.BranchPolicy do
  @moduledoc """
  Enforces branch protection rules for a source code repository.
  Policies specify required review counts, status checks, and merge strategies.
  """

  alias Scm.Repositories.{Branch, PullRequest}

  @type rule :: %{
          branch_pattern: String.t(),
          required_reviews: non_neg_integer(),
          required_checks: [String.t()],
          allowed_merge_strategies: [atom()]
        }

  @type policy :: %{rules: [rule()]}

  @type merge_verdict ::
          :approved
          | {:blocked, [String.t()]}

  @doc """
  Evaluates whether `pull_request` satisfies the first matching rule
  in `policy` for its target branch.

  Returns `:approved` or `{:blocked, reasons}`.
  """
  @spec evaluate(policy(), PullRequest.t()) :: merge_verdict()
  def evaluate(%{rules: rules}, %PullRequest{} = pr) do
    case find_matching_rule(rules, pr.target_branch) do
      nil -> :approved
      rule -> apply_rule(rule, pr)
    end
  end

  @doc """
  Builds a default policy with sensible protections for main and release branches.
  """
  @spec default_policy() :: policy()
  def default_policy do
    %{
      rules: [
        %{
          branch_pattern: "main",
          required_reviews: 2,
          required_checks: ["ci/tests", "ci/lint"],
          allowed_merge_strategies: [:squash, :merge]
        },
        %{
          branch_pattern: "release/*",
          required_reviews: 1,
          required_checks: ["ci/tests"],
          allowed_merge_strategies: [:merge]
        }
      ]
    }
  end

  @doc """
  Checks if `branch_name` matches a glob-style `pattern`.
  Supports `*` wildcard at the end of a path segment.
  """
  @spec branch_matches?(String.t(), String.t()) :: boolean()
  def branch_matches?(pattern, branch_name)
      when is_binary(pattern) and is_binary(branch_name) do
    pattern_parts = String.split(pattern, "/")
    branch_parts = String.split(branch_name, "/")

    if length(pattern_parts) != length(branch_parts) do
      false
    else
      Enum.zip(pattern_parts, branch_parts)
      |> Enum.all?(fn {p, b} -> p == "*" or p == b end)
    end
  end

  defp find_matching_rule(rules, %Branch{name: name}) do
    Enum.find(rules, fn rule -> branch_matches?(rule.branch_pattern, name) end)
  end

  defp apply_rule(rule, pr) do
    reasons =
      []
      |> check_reviews(rule, pr)
      |> check_status_checks(rule, pr)
      |> check_merge_strategy(rule, pr)

    if reasons == [], do: :approved, else: {:blocked, reasons}
  end

  defp check_reviews(reasons, rule, pr) do
    approved = length(pr.approved_by)

    if approved >= rule.required_reviews do
      reasons
    else
      needed = rule.required_reviews - approved
      ["#{needed} more approval(s) required" | reasons]
    end
  end

  defp check_status_checks(reasons, rule, pr) do
    passed = MapSet.new(pr.passed_checks)

    failing =
      rule.required_checks
      |> Enum.reject(fn check -> MapSet.member?(passed, check) end)

    if failing == [] do
      reasons
    else
      ["failing required checks: #{Enum.join(failing, ", ")}" | reasons]
    end
  end

  defp check_merge_strategy(reasons, rule, pr) do
    if pr.merge_strategy in rule.allowed_merge_strategies do
      reasons
    else
      allowed = Enum.map_join(rule.allowed_merge_strategies, ", ", &inspect/1)
      ["merge strategy #{inspect(pr.merge_strategy)} not allowed; use: #{allowed}" | reasons]
    end
  end
end
```
