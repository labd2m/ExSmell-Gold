# Annotated Example 29

- **Smell name:** Using exceptions for control-flow
- **Expected smell location:** `RefundEngine.process/2` (library) and `CustomerSupport.issue_refund/2` (client)
- **Affected function(s):** `RefundEngine.process/2`, `CustomerSupport.issue_refund/2`
- **Short explanation:** `RefundEngine.process/2` raises exceptions for refund-window expiry, already-refunded charges, and amounts exceeding the original charge — all of which are routine outcomes in a support tool. The absence of a tuple-returning variant forces `CustomerSupport.issue_refund/2` to wrap every refund attempt in `try...rescue` for normal decision-making.

```elixir
defmodule RefundEngine do
  @moduledoc """
  Processes full and partial refunds against settled payment charges.
  Enforces business rules around refund eligibility and amounts.
  """

  defmodule RefundWindowExpiredError do
    defexception [:message, :charge_id, :charged_at, :window_days]
  end

  defmodule AlreadyRefundedError do
    defexception [:message, :charge_id, :existing_refund_id]
  end

  defmodule ExceedsOriginalAmountError do
    defexception [:message, :charge_id, :refund_amount, :max_refundable]
  end

  defmodule ChargeNotFoundError do
    defexception [:message, :charge_id]
  end

  defmodule InvalidRefundAmountError do
    defexception [:message, :amount]
  end

  @refund_window_days 90

  @charges %{
    "ch_001" => %{id: "ch_001", amount_cents: 4999, charged_at: ~U[2025-08-01 00:00:00Z], refunded: false, refund_id: nil},
    "ch_002" => %{id: "ch_002", amount_cents: 9900, charged_at: ~U[2024-01-01 00:00:00Z], refunded: false, refund_id: nil},
    "ch_003" => %{id: "ch_003", amount_cents: 2500, charged_at: ~U[2025-07-15 00:00:00Z], refunded: true, refund_id: "re_999"}
  }

  # VALIDATION: SMELL START - Using exceptions for control-flow
  # VALIDATION: This is a smell because a charge being outside the refund
  # window, already refunded, or an amount exceeding the original are all
  # normal business-rule outcomes in a support tool. Raising exceptions for
  # these — without offering {:ok, _}/{:error, _} — leaves clients no choice
  # but to use try...rescue to decide what to tell a support agent.
  def process(charge_id, refund_amount_cents) when not is_integer(refund_amount_cents) or refund_amount_cents <= 0 do
    raise InvalidRefundAmountError,
      message: "Refund amount must be a positive integer (cents), got: #{inspect(refund_amount_cents)}",
      amount: refund_amount_cents
  end

  def process(charge_id, refund_amount_cents) do
    charge = Map.get(@charges, charge_id)

    if is_nil(charge) do
      raise ChargeNotFoundError,
        message: "No charge found with ID '#{charge_id}'",
        charge_id: charge_id
    end

    if charge.refunded do
      raise AlreadyRefundedError,
        message: "Charge '#{charge_id}' has already been refunded (refund: #{charge.refund_id})",
        charge_id: charge_id,
        existing_refund_id: charge.refund_id
    end

    age_days = DateTime.diff(DateTime.utc_now(), charge.charged_at, :second) |> div(86_400)

    if age_days > @refund_window_days do
      raise RefundWindowExpiredError,
        message:
          "Charge '#{charge_id}' is #{age_days} days old; refund window is #{@refund_window_days} days",
        charge_id: charge_id,
        charged_at: charge.charged_at,
        window_days: @refund_window_days
    end

    if refund_amount_cents > charge.amount_cents do
      raise ExceedsOriginalAmountError,
        message:
          "Refund of #{refund_amount_cents}¢ exceeds original charge of #{charge.amount_cents}¢",
        charge_id: charge_id,
        refund_amount: refund_amount_cents,
        max_refundable: charge.amount_cents
    end

    %{
      refund_id: "re_#{System.unique_integer([:positive])}",
      charge_id: charge_id,
      amount_cents: refund_amount_cents,
      is_partial: refund_amount_cents < charge.amount_cents,
      processed_at: DateTime.utc_now(),
      status: :succeeded
    }
  end
  # VALIDATION: SMELL END
end

defmodule CustomerSupport do
  @moduledoc """
  Provides refund tooling for customer support agents.
  Translates refund engine outcomes into actionable agent messages.
  """

  require Logger

  def issue_refund(charge_id, amount_cents) do
    Logger.info("Support agent requesting refund of #{amount_cents}¢ for charge #{charge_id}")

    # VALIDATION: SMELL START - Using exceptions for control-flow
    # VALIDATION: This is a smell because a support agent routinely encounters
    # already-refunded charges and expired windows. These should be handled with
    # normal control flow, not try...rescue, since no exceptional condition has
    # actually occurred from the system's perspective.
    try do
      refund = RefundEngine.process(charge_id, amount_cents)

      Logger.info("Refund #{refund.refund_id} processed for charge #{charge_id}")
      {:ok, refund}
    rescue
      e in RefundEngine.AlreadyRefundedError ->
        Logger.info("Charge #{e.charge_id} already refunded (#{e.existing_refund_id})")
        {:error, :already_refunded, e.existing_refund_id}

      e in RefundEngine.RefundWindowExpiredError ->
        Logger.warning(
          "Refund window expired for #{e.charge_id}; charged #{e.charged_at}, window #{e.window_days}d"
        )
        {:error, :window_expired, e.window_days}

      e in RefundEngine.ExceedsOriginalAmountError ->
        Logger.warning("Refund #{e.refund_amount}¢ exceeds original #{e.max_refundable}¢")
        {:error, :exceeds_original, e.max_refundable}

      e in RefundEngine.ChargeNotFoundError ->
        Logger.error("Charge not found: #{e.charge_id}")
        {:error, :charge_not_found}

      e in RefundEngine.InvalidRefundAmountError ->
        Logger.warning("Invalid refund amount: #{e.message}")
        {:error, :invalid_amount}
    end
    # VALIDATION: SMELL END
  end
end
```
