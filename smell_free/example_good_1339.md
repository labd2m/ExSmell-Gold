```elixir
defmodule Tax.Calculator do
  @moduledoc """
  Computes applicable taxes for a sale based on jurisdiction rules.

  Tax rules are loaded per-jurisdiction at call time from a pluggable rule
  store, keeping the calculation engine free of global state. All arithmetic
  uses integer cents to avoid floating-point rounding errors.
  """

  alias Tax.Calculator.{JurisdictionRules, TaxLine, TaxResult, RuleStore}

  @doc """
  Calculates all applicable taxes for a sale.

  Returns a `TaxResult` with a breakdown of each applied tax line.
  """
  @spec calculate(map(), String.t(), String.t(), keyword()) ::
          {:ok, TaxResult.t()} | {:error, String.t()}
  def calculate(sale, origin_jurisdiction, destination_jurisdiction, opts \\ [])
      when is_map(sale) and is_binary(origin_jurisdiction) and is_binary(destination_jurisdiction) do
    store = Keyword.get(opts, :rule_store, RuleStore.default())

    with {:ok, rules} <- RuleStore.fetch(store, destination_jurisdiction),
         {:ok, taxable_amount} <- extract_taxable_amount(sale) do
      tax_lines = apply_rules(rules, taxable_amount, origin_jurisdiction)
      total_tax = Enum.sum(Enum.map(tax_lines, & &1.amount_cents))
      {:ok, TaxResult.new(taxable_amount, total_tax, destination_jurisdiction, tax_lines)}
    end
  end

  @doc """
  Returns the effective total tax rate for a jurisdiction as a percentage.
  """
  @spec effective_rate(String.t(), keyword()) :: {:ok, float()} | {:error, String.t()}
  def effective_rate(jurisdiction, opts \\ []) when is_binary(jurisdiction) do
    store = Keyword.get(opts, :rule_store, RuleStore.default())

    with {:ok, rules} <- RuleStore.fetch(store, jurisdiction) do
      total_rate = Enum.sum(Enum.map(rules.tax_lines, & &1.rate_pct))
      {:ok, total_rate}
    end
  end

  defp extract_taxable_amount(%{taxable_amount_cents: amount}) when is_integer(amount) and amount > 0 do
    {:ok, amount}
  end

  defp extract_taxable_amount(%{subtotal_cents: sub, taxable_shipping_cents: ship})
       when is_integer(sub) and is_integer(ship) do
    {:ok, sub + ship}
  end

  defp extract_taxable_amount(%{subtotal_cents: sub}) when is_integer(sub) and sub >= 0 do
    {:ok, sub}
  end

  defp extract_taxable_amount(_), do: {:error, "sale is missing taxable amount fields"}

  defp apply_rules(%JurisdictionRules{tax_lines: rule_lines, nexus_origins: nexus}, taxable, origin) do
    if nexus == :all or origin in nexus do
      Enum.map(rule_lines, fn line ->
        amount = round(taxable * line.rate_pct / 100)
        TaxLine.new(line.name, line.rate_pct, amount)
      end)
    else
      []
    end
  end
end

defmodule Tax.Calculator.JurisdictionRules do
  @moduledoc false

  @enforce_keys [:jurisdiction, :tax_lines]
  defstruct [:jurisdiction, :tax_lines, nexus_origins: :all]

  @type rule_line :: %{name: String.t(), rate_pct: float()}
  @type t :: %__MODULE__{
          jurisdiction: String.t(),
          tax_lines: [rule_line()],
          nexus_origins: :all | [String.t()]
        }
end

defmodule Tax.Calculator.TaxLine do
  @moduledoc false

  @enforce_keys [:name, :rate_pct, :amount_cents]
  defstruct [:name, :rate_pct, :amount_cents]

  @type t :: %__MODULE__{name: String.t(), rate_pct: float(), amount_cents: integer()}

  @spec new(String.t(), float(), integer()) :: t()
  def new(name, rate, amount), do: %__MODULE__{name: name, rate_pct: rate, amount_cents: amount}
end

defmodule Tax.Calculator.TaxResult do
  @moduledoc "Typed outcome of a tax calculation."

  @enforce_keys [:taxable_cents, :total_tax_cents, :jurisdiction, :lines, :calculated_at]
  defstruct [:taxable_cents, :total_tax_cents, :jurisdiction, :lines, :calculated_at]

  @type t :: %__MODULE__{
          taxable_cents: non_neg_integer(),
          total_tax_cents: non_neg_integer(),
          jurisdiction: String.t(),
          lines: [Tax.Calculator.TaxLine.t()],
          calculated_at: DateTime.t()
        }

  @spec new(non_neg_integer(), non_neg_integer(), String.t(), [Tax.Calculator.TaxLine.t()]) :: t()
  def new(taxable, total, jurisdiction, lines) do
    %__MODULE__{
      taxable_cents: taxable,
      total_tax_cents: total,
      jurisdiction: jurisdiction,
      lines: lines,
      calculated_at: DateTime.utc_now()
    }
  end

  @spec effective_rate(t()) :: float()
  def effective_rate(%__MODULE__{taxable_cents: 0}), do: 0.0
  def effective_rate(%__MODULE__{taxable_cents: taxable, total_tax_cents: total}) do
    total / taxable * 100
  end
end

defmodule Tax.Calculator.RuleStore do
  @moduledoc "Behaviour for jurisdiction tax rule stores."

  @callback fetch(String.t()) ::
              {:ok, Tax.Calculator.JurisdictionRules.t()} | {:error, String.t()}

  @spec fetch(module(), String.t()) ::
          {:ok, Tax.Calculator.JurisdictionRules.t()} | {:error, String.t()}
  def fetch(store_module, jurisdiction), do: store_module.fetch(jurisdiction)

  @spec default() :: module()
  def default, do: Application.get_env(:tax, :rule_store, Tax.Calculator.Stores.Database)
end
```
