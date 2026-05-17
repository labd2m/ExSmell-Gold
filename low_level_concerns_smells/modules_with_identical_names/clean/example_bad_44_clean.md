```elixir
# ── file: lib/fraud/detector.ex ─────────────────────────────────────────────

defmodule Fraud.Detector do
  @moduledoc """
  Real-time fraud detection for payment transactions and account actions.
  Defined in `lib/fraud/detector.ex`.
  """

  alias Fraud.{RuleEngine, SignalStore, FlagStore, RiskModel}

  @risk_thresholds %{
    low: 0..30,
    medium: 31..70,
    high: 71..90,
    critical: 91..100
  }

  @type transaction :: %{
    id: String.t(),
    account_id: String.t(),
    amount_cents: pos_integer(),
    currency: String.t(),
    merchant_id: String.t(),
    ip_address: String.t(),
    device_fingerprint: String.t() | nil,
    occurred_at: DateTime.t()
  }

  @doc """
  Evaluate a transaction against all active fraud rules.
  Returns `{:ok, decision}` where decision is `:allow`, `:review`, or `:block`.
  """
  @spec evaluate(transaction(), keyword()) ::
          {:ok, :allow | :review | :block, map()} | {:error, String.t()}
  def evaluate(transaction, opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 200)

    with {:ok, signals} <- SignalStore.fetch_recent(transaction.account_id, window_seconds: 3600),
         {:ok, risk_score} <- RiskModel.score(transaction, signals) do
      rule_result = RuleEngine.apply_all(transaction, signals, score: risk_score)

      decision =
        cond do
          rule_result.block? -> :block
          risk_score >= 71 or rule_result.review? -> :review
          true -> :allow
        end

      outcome = %{
        decision: decision,
        risk_score: risk_score,
        triggered_rules: rule_result.triggered,
        evaluated_at: DateTime.utc_now()
      }

      if decision in [:review, :block] do
        flag(transaction.id, %{score: risk_score, rules: rule_result.triggered})
      end

      {:ok, decision, outcome}
    end
  end

  @doc "Compute a numeric fraud risk score (0-100) for a transaction."
  @spec score(transaction()) :: {:ok, integer()} | {:error, String.t()}
  def score(transaction) do
    with {:ok, signals} <- SignalStore.fetch_recent(transaction.account_id, window_seconds: 3600) do
      RiskModel.score(transaction, signals)
    end
  end

  @doc "Manually flag a transaction for fraud review."
  @spec flag(String.t(), map()) :: :ok
  def flag(transaction_id, meta \\ %{}) do
    FlagStore.put(%{
      transaction_id: transaction_id,
      reason: Map.get(meta, :reason, "automated_detection"),
      score: Map.get(meta, :score),
      flagged_at: DateTime.utc_now(),
      status: :open
    })
  end

  @doc "Clear an existing fraud flag after manual review."
  @spec clear_flag(String.t()) :: :ok | {:error, String.t()}
  def clear_flag(transaction_id) do
    case FlagStore.fetch(transaction_id) do
      {:ok, flag} ->
        FlagStore.update(flag.id, %{status: :cleared, cleared_at: DateTime.utc_now()})

      :not_found ->
        {:error, "No open flag for transaction: #{transaction_id}"}
    end
  end

  @doc "Return the aggregated risk summary for an account over the last 30 days."
  @spec risk_summary(String.t()) :: {:ok, map()} | {:error, String.t()}
  def risk_summary(account_id) do
    since = DateTime.add(DateTime.utc_now(), -86_400 * 30, :second)
    signals = SignalStore.fetch_range(account_id, from: since)

    flags =
      FlagStore.query(account_id: account_id, from: since)

    avg_score =
      case signals do
        [] ->
          0

        _ ->
          signals
          |> Enum.map(& &1.risk_score)
          |> then(fn scores -> Enum.sum(scores) / length(scores) end)
          |> round()
      end

    level =
      Enum.find_value(@risk_thresholds, :low, fn {level, range} ->
        if avg_score in range, do: level
      end)

    {:ok,
     %{
       account_id: account_id,
       avg_score: avg_score,
       risk_level: level,
       total_flags: length(flags),
       open_flags: Enum.count(flags, &(&1.status == :open)),
       window_days: 30
     }}
  end
end


# ── file: lib/fraud/detector_allowlist.ex  

defmodule Fraud.Detector do
  @moduledoc """
  Allowlist management for known-safe merchants and trusted accounts.
  Was intended to be `Fraud.Detector.Allowlist` but was accidentally named
  identically to the core fraud detector.
  """

  alias Fraud.AllowlistStore

  @doc "Add a merchant or account to the fraud detection allowlist."
  @spec allow(atom(), String.t(), map()) :: :ok | {:error, String.t()}
  def allow(entity_type, entity_id, meta \\ %{})
      when entity_type in [:merchant, :account] do
    entry = %{
      entity_type: entity_type,
      entity_id: entity_id,
      reason: Map.get(meta, :reason, "manual"),
      added_by: Map.get(meta, :added_by),
      expires_at: Map.get(meta, :expires_at),
      added_at: DateTime.utc_now()
    }

    AllowlistStore.put(entity_type, entity_id, entry)
  end

  @doc "Remove an entity from the allowlist."
  @spec revoke(atom(), String.t()) :: :ok | {:error, String.t()}
  def revoke(entity_type, entity_id) do
    case AllowlistStore.delete(entity_type, entity_id) do
      :ok -> :ok
      :not_found -> {:error, "#{entity_type} #{entity_id} is not on the allowlist"}
    end
  end

  @doc "Check whether an entity is on the allowlist."
  @spec allowed?(atom(), String.t()) :: boolean()
  def allowed?(entity_type, entity_id) do
    case AllowlistStore.fetch(entity_type, entity_id) do
      {:ok, %{expires_at: nil}} -> true
      {:ok, %{expires_at: exp}} -> DateTime.compare(exp, DateTime.utc_now()) == :gt
      :not_found -> false
    end
  end

  @doc "Purge expired allowlist entries."
  @spec purge_expired() :: {:ok, non_neg_integer()}
  def purge_expired do
    now = DateTime.utc_now()
    all = AllowlistStore.all()
    expired = Enum.filter(all, &(&1.expires_at != nil and DateTime.compare(&1.expires_at, now) != :gt))
    Enum.each(expired, &AllowlistStore.delete(&1.entity_type, &1.entity_id))
    {:ok, length(expired)}
  end
end

```
