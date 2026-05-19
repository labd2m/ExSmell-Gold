```elixir
defmodule MyApp.LoyaltyPointsAgent do
  @moduledoc """
  Manages customer loyalty point balances, earning rules, redemption,
  tier upgrades, and point expiry for the rewards programme.
  """

  use Agent

  alias MyApp.{Repo, Mailer, AuditLog}
  alias MyApp.Loyalty.{Account, PointsLedger, TierPolicy}

  @tiers [
    %{name: :bronze, min_points: 0},
    %{name: :silver, min_points: 1_000},
    %{name: :gold, min_points: 5_000},
    %{name: :platinum, min_points: 20_000}
  ]

  @point_expiry_days 365

  def start_link(_opts) do
    accounts = Repo.all(Account) |> Enum.into(%{}, &{&1.customer_id, &1})
    Agent.start_link(fn -> %{accounts: accounts, ledger: []} end, name: __MODULE__)
  end

  def get_balance(customer_id) do
    Agent.get(__MODULE__, fn state ->
      case Map.get(state.accounts, customer_id) do
        nil -> {:error, :not_found}
        account -> {:ok, account.balance}
      end
    end)
  end

  def get_tier(customer_id) do
    Agent.get(__MODULE__, fn state ->
      case Map.get(state.accounts, customer_id) do
        nil -> {:error, :not_found}
        account -> {:ok, account.tier}
      end
    end)
  end

  def earn_points(customer_id, base_points, transaction_ref) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.fetch(state.accounts, customer_id) do
        :error ->
          {{:error, :account_not_found}, state}

        {:ok, account} ->
          multiplier = tier_multiplier(account.tier)
          earned = trunc(base_points * multiplier)

          entry = %PointsLedger{
            id: Ecto.UUID.generate(),
            customer_id: customer_id,
            delta: earned,
            kind: :earn,
            reference: transaction_ref,
            expires_at: DateTime.add(DateTime.utc_now(), @point_expiry_days * 86_400, :second),
            recorded_at: DateTime.utc_now()
          }

          Repo.insert!(entry)

          new_balance = account.balance + earned
          new_lifetime = account.lifetime_earned + earned
          new_tier = compute_tier(new_lifetime)

          tier_upgraded? = new_tier != account.tier

          updated_account = %{
            account
            | balance: new_balance,
              lifetime_earned: new_lifetime,
              tier: new_tier,
              updated_at: DateTime.utc_now()
          }

          Repo.update!(updated_account)
          AuditLog.record(:points_earned, %{customer: customer_id, earned: earned})

          if tier_upgraded? do
            Mailer.deliver_tier_upgrade(customer_id, new_tier)
            AuditLog.record(:tier_upgraded, %{customer: customer_id, tier: new_tier})
          end

          new_state = %{
            state
            | accounts: Map.put(state.accounts, customer_id, updated_account),
              ledger: [entry | Enum.take(state.ledger, 9_999)]
          }

          {{:ok, %{earned: earned, balance: new_balance, tier: new_tier}}, new_state}
      end
    end)
  end

  def redeem_points(customer_id, points_to_redeem, redemption_ref) do
    Agent.get_and_update(__MODULE__, fn state ->
      policy = TierPolicy.for_tier(:all)

      with {:ok, account} <- Map.fetch(state.accounts, customer_id),
           true <- points_to_redeem >= policy.minimum_redemption,
           true <- account.balance >= points_to_redeem do
        entry = %PointsLedger{
          id: Ecto.UUID.generate(),
          customer_id: customer_id,
          delta: -points_to_redeem,
          kind: :redeem,
          reference: redemption_ref,
          expires_at: nil,
          recorded_at: DateTime.utc_now()
        }

        Repo.insert!(entry)
        updated_account = %{account | balance: account.balance - points_to_redeem}
        Repo.update!(updated_account)
        AuditLog.record(:points_redeemed, %{customer: customer_id, redeemed: points_to_redeem})

        new_state = %{
          state
          | accounts: Map.put(state.accounts, customer_id, updated_account),
            ledger: [entry | Enum.take(state.ledger, 9_999)]
        }

        {{:ok, %{redeemed: points_to_redeem, balance: updated_account.balance}}, new_state}
      else
        :error -> {{:error, :account_not_found}, state}
        false -> {{:error, :insufficient_points_or_below_minimum}, state}
      end
    end)
  end

  def expire_points(customer_id) do
    now = DateTime.utc_now()

    Agent.get_and_update(__MODULE__, fn state ->
      case Map.fetch(state.accounts, customer_id) do
        :error ->
          {{:error, :not_found}, state}

        {:ok, account} ->
          expired_entries =
            state.ledger
            |> Enum.filter(fn e ->
              e.customer_id == customer_id and
                e.kind == :earn and
                not is_nil(e.expires_at) and
                DateTime.compare(e.expires_at, now) == :lt
            end)

          expired_points = Enum.sum(Enum.map(expired_entries, & &1.delta))

          if expired_points > 0 do
            new_balance = max(0, account.balance - expired_points)
            updated_account = %{account | balance: new_balance}
            Repo.update!(updated_account)
            Mailer.deliver_points_expiry_notice(customer_id, expired_points)
            AuditLog.record(:points_expired, %{customer: customer_id, expired: expired_points})

            new_state = put_in(state, [:accounts, customer_id], updated_account)
            {{:ok, expired_points}, new_state}
          else
            {{:ok, 0}, state}
          end
      end
    end)
  end

  defp compute_tier(lifetime_points) do
    @tiers
    |> Enum.filter(&(lifetime_points >= &1.min_points))
    |> List.last()
    |> Map.get(:name)
  end

  defp tier_multiplier(:platinum), do: 3.0
  defp tier_multiplier(:gold), do: 2.0
  defp tier_multiplier(:silver), do: 1.5
  defp tier_multiplier(_), do: 1.0
end
```
