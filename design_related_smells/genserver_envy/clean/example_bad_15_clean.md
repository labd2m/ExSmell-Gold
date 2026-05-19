```elixir
defmodule MyApp.PromoCodeAgent do
  @moduledoc """
  Manages promotional codes including creation, redemption validation,
  and usage tracking for the checkout pipeline.
  """

  use Agent

  alias MyApp.{Repo, AuditLog, Mailer}
  alias MyApp.Promotions.{PromoCode, Redemption}

  def start_link(_opts) do
    codes =
      Repo.all(PromoCode)
      |> Enum.into(%{}, &{&1.code, &1})

    Agent.start_link(fn -> %{codes: codes, redemptions: %{}} end, name: __MODULE__)
  end

  def get_promo(code) do
    Agent.get(__MODULE__, fn state -> Map.get(state.codes, code) end)
  end


  def create_promo(attrs, created_by) do
    Agent.get_and_update(__MODULE__, fn state ->
      if Map.has_key?(state.codes, attrs.code) do
        {{:error, :code_already_exists}, state}
      else
        promo = %PromoCode{
          code: attrs.code,
          discount_percent: attrs.discount_percent,
          max_uses: attrs.max_uses,
          per_user_limit: Map.get(attrs, :per_user_limit, 1),
          valid_from: attrs.valid_from,
          valid_until: attrs.valid_until,
          use_count: 0,
          created_by: created_by,
          created_at: DateTime.utc_now()
        }

        case Repo.insert(promo) do
          {:ok, saved} ->
            AuditLog.record(:promo_created, %{code: saved.code, by: created_by})
            new_state = put_in(state, [:codes, saved.code], saved)
            {{:ok, saved}, new_state}

          {:error, changeset} ->
            {{:error, changeset}, state}
        end
      end
    end)
  end

  def redeem(code, user_id, cart_total_cents) do
    Agent.get_and_update(__MODULE__, fn state ->
      now = DateTime.utc_now()

      with {:ok, promo} <- Map.fetch(state.codes, code),
           true <- DateTime.compare(promo.valid_from, now) in [:lt, :eq],
           true <- DateTime.compare(promo.valid_until, now) == :gt,
           true <- is_nil(promo.max_uses) or promo.use_count < promo.max_uses do
        user_redemptions =
          state.redemptions
          |> Map.values()
          |> Enum.count(&(&1.user_id == user_id and &1.promo_code == code))

        if user_redemptions >= promo.per_user_limit do
          {{:error, :per_user_limit_reached}, state}
        else
          discount_cents = trunc(cart_total_cents * promo.discount_percent / 100)

          redemption = %Redemption{
            id: Ecto.UUID.generate(),
            promo_code: code,
            user_id: user_id,
            discount_cents: discount_cents,
            redeemed_at: now
          }

          case Repo.insert(redemption) do
            {:ok, saved} ->
              updated_promo = %{promo | use_count: promo.use_count + 1}
              Repo.update!(updated_promo)

              AuditLog.record(:promo_redeemed, %{
                code: code,
                user_id: user_id,
                discount_cents: discount_cents
              })

              new_state = %{
                state
                | codes: Map.put(state.codes, code, updated_promo),
                  redemptions: Map.put(state.redemptions, saved.id, saved)
              }

              {{:ok, %{discount_cents: discount_cents, redemption_id: saved.id}}, new_state}

            {:error, reason} ->
              {{:error, reason}, state}
          end
        end
      else
        :error -> {{:error, :code_not_found}, state}
        false -> {{:error, :promo_not_active}, state}
      end
    end)
  end

  def expire_promo(code) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.fetch(state.codes, code) do
        :error ->
          {{:error, :not_found}, state}

        {:ok, promo} ->
          expired = %{promo | valid_until: DateTime.utc_now()}
          Repo.update!(expired)
          AuditLog.record(:promo_expired, %{code: code})
          Mailer.notify_promo_expired(code)
          {{:ok, expired}, %{state | codes: Map.put(state.codes, code, expired)}}
      end
    end)
  end


  def list_active do
    now = DateTime.utc_now()

    Agent.get(__MODULE__, fn state ->
      state.codes
      |> Map.values()
      |> Enum.filter(fn p ->
        DateTime.compare(p.valid_from, now) in [:lt, :eq] and
          DateTime.compare(p.valid_until, now) == :gt and
          (is_nil(p.max_uses) or p.use_count < p.max_uses)
      end)
    end)
  end
end
```
