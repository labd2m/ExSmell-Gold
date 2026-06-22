```elixir
defmodule Compliance.Rule do
  @moduledoc """
  A named compliance rule that evaluates a record and returns a structured finding.
  """

  @type severity :: :info | :warning | :violation

  @type finding :: %{
          rule: String.t(),
          severity: severity(),
          message: String.t(),
          field: atom() | nil
        }

  @callback name() :: String.t()
  @callback severity() :: severity()
  @callback evaluate(record :: map()) :: :pass | {:fail, String.t()}
end

defmodule Compliance.Engine do
  alias Compliance.Rule

  @moduledoc """
  Runs a set of compliance rule modules against a record and
  aggregates findings by severity. Returns a structured report
  indicating overall compliance status.
  """

  @type report :: %{
          compliant: boolean(),
          findings: [Rule.finding()],
          violations: non_neg_integer(),
          warnings: non_neg_integer()
        }

  @spec evaluate(map(), [module()]) :: report()
  def evaluate(record, rule_modules) when is_map(record) and is_list(rule_modules) do
    findings =
      rule_modules
      |> Enum.flat_map(&run_rule(&1, record))

    violations = Enum.count(findings, &(&1.severity == :violation))
    warnings = Enum.count(findings, &(&1.severity == :warning))

    %{
      compliant: violations == 0,
      findings: findings,
      violations: violations,
      warnings: warnings
    }
  end

  defp run_rule(rule_module, record) do
    case rule_module.evaluate(record) do
      :pass -> []
      {:fail, message} ->
        [%{rule: rule_module.name(), severity: rule_module.severity(),
           message: message, field: nil}]
    end
  end
end

defmodule Compliance.Rules.RequiredEmail do
  @behaviour Compliance.Rule

  @impl Compliance.Rule
  def name, do: "required_email"

  @impl Compliance.Rule
  def severity, do: :violation

  @impl Compliance.Rule
  def evaluate(%{email: email}) when is_binary(email) and email != "" do
    if String.match?(email, ~r/^[^\s]+@[^\s]+\.[^\s]+$/) do
      :pass
    else
      {:fail, "email must be a valid address"}
    end
  end

  def evaluate(_record), do: {:fail, "email is required"}
end

defmodule Compliance.Rules.GdprConsentRequired do
  @behaviour Compliance.Rule

  @impl Compliance.Rule
  def name, do: "gdpr_consent_required"

  @impl Compliance.Rule
  def severity, do: :violation

  @impl Compliance.Rule
  def evaluate(%{gdpr_consent: true}), do: :pass
  def evaluate(_record), do: {:fail, "GDPR consent must be explicitly recorded"}
end

defmodule Compliance.Rules.PhoneRecommended do
  @behaviour Compliance.Rule

  @impl Compliance.Rule
  def name, do: "phone_recommended"

  @impl Compliance.Rule
  def severity, do: :warning

  @impl Compliance.Rule
  def evaluate(%{phone: phone}) when is_binary(phone) and phone != "", do: :pass
  def evaluate(_record), do: {:fail, "phone number is recommended for account recovery"}
end
```
