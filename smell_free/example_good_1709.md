```elixir
defmodule Moderation.Pipeline do
  @moduledoc """
  Evaluates user-submitted content through an ordered chain of moderation rules.

  Each rule is a module implementing the `Moderation.Rule` behaviour. Rules are
  executed in priority order and may produce :pass, :flag, or :block decisions.
  The pipeline short-circuits on the first :block decision.
  """

  alias Moderation.{Rule, Decision, ContentSubmission}

  @type rule_module :: module()

  @doc """
  Runs a content submission through the configured rule chain.

  Returns the most restrictive `Decision` produced by any rule.
  Rules returning `:pass` do not affect the final outcome.
  """
  @spec evaluate(ContentSubmission.t(), [rule_module()]) :: Decision.t()
  def evaluate(%ContentSubmission{} = submission, rules) when is_list(rules) do
    sorted_rules = Enum.sort_by(rules, &Rule.priority/1)
    run_rules(submission, sorted_rules, Decision.pass())
  end

  defp run_rules(_submission, [], current_decision), do: current_decision

  defp run_rules(submission, [rule | rest], current_decision) do
    decision = Rule.evaluate(rule, submission)

    cond do
      Decision.blocks?(decision) ->
        decision

      Decision.more_restrictive?(decision, current_decision) ->
        run_rules(submission, rest, decision)

      true ->
        run_rules(submission, rest, current_decision)
    end
  end
end

defmodule Moderation.Rule do
  @moduledoc "Behaviour contract for content moderation rules."

  alias Moderation.{ContentSubmission, Decision}

  @callback evaluate(ContentSubmission.t()) :: Decision.t()
  @callback priority() :: non_neg_integer()

  @spec evaluate(module(), ContentSubmission.t()) :: Decision.t()
  def evaluate(rule_module, submission), do: rule_module.evaluate(submission)

  @spec priority(module()) :: non_neg_integer()
  def priority(rule_module), do: rule_module.priority()
end

defmodule Moderation.Decision do
  @moduledoc "Outcome of a moderation rule evaluation."

  @enforce_keys [:verdict, :rule, :reason]
  defstruct [:verdict, :rule, :reason, metadata: %{}]

  @type verdict :: :pass | :flag | :block
  @type t :: %__MODULE__{
          verdict: verdict(),
          rule: String.t() | nil,
          reason: String.t() | nil,
          metadata: map()
        }

  @spec pass() :: t()
  def pass, do: %__MODULE__{verdict: :pass, rule: nil, reason: nil}

  @spec flag(String.t(), String.t(), map()) :: t()
  def flag(rule, reason, metadata \\ %{}),
    do: %__MODULE__{verdict: :flag, rule: rule, reason: reason, metadata: metadata}

  @spec block(String.t(), String.t(), map()) :: t()
  def block(rule, reason, metadata \\ %{}),
    do: %__MODULE__{verdict: :block, rule: rule, reason: reason, metadata: metadata}

  @spec blocks?(t()) :: boolean()
  def blocks?(%__MODULE__{verdict: :block}), do: true
  def blocks?(_), do: false

  @spec more_restrictive?(t(), t()) :: boolean()
  def more_restrictive?(%__MODULE__{verdict: :block}, %__MODULE__{verdict: v}) when v != :block, do: true
  def more_restrictive?(%__MODULE__{verdict: :flag}, %__MODULE__{verdict: :pass}), do: true
  def more_restrictive?(_, _), do: false
end

defmodule Moderation.ContentSubmission do
  @moduledoc "Typed value object representing submitted user content."

  @enforce_keys [:id, :author_id, :body, :content_type]
  defstruct [:id, :author_id, :body, :content_type, metadata: %{}]

  @type content_type :: :post | :comment | :bio | :username
  @type t :: %__MODULE__{
          id: String.t(),
          author_id: String.t(),
          body: String.t(),
          content_type: content_type(),
          metadata: map()
        }

  @spec new(String.t(), String.t(), String.t(), content_type(), map()) :: t()
  def new(id, author_id, body, content_type, metadata \\ %{})
      when is_binary(id) and is_binary(author_id) and is_binary(body) and is_atom(content_type) do
    %__MODULE__{id: id, author_id: author_id, body: body, content_type: content_type, metadata: metadata}
  end
end

defmodule Moderation.Rules.ProfanityFilter do
  @moduledoc "Flags content containing terms from a configurable blocklist."

  @behaviour Moderation.Rule

  @blocked_terms ~w[spam scam badword]

  @impl Moderation.Rule
  def priority, do: 10

  @impl Moderation.Rule
  def evaluate(%Moderation.ContentSubmission{body: body, id: id}) do
    matched = Enum.filter(@blocked_terms, &String.contains?(String.downcase(body), &1))

    if matched == [] do
      Moderation.Decision.pass()
    else
      Moderation.Decision.flag("profanity_filter", "matched terms: #{Enum.join(matched, ", ")}",
        %{matched_terms: matched, submission_id: id}
      )
    end
  end
end

defmodule Moderation.Rules.LengthGuard do
  @moduledoc "Blocks submissions that exceed the maximum allowed body length."

  @behaviour Moderation.Rule

  @max_length 10_000

  @impl Moderation.Rule
  def priority, do: 5

  @impl Moderation.Rule
  def evaluate(%Moderation.ContentSubmission{body: body}) do
    if String.length(body) <= @max_length do
      Moderation.Decision.pass()
    else
      Moderation.Decision.block("length_guard", "content exceeds #{@max_length} characters")
    end
  end
end
```
