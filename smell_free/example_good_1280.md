```elixir
defmodule Commerce.Discounts do
  @moduledoc """
  Evaluates coupon codes and discount rules against a cart to produce
  an itemised discount breakdown.

  Discount evaluation is pure: no I/O occurs during application. Coupon
  lookup is separated from application so the two concerns can be tested
  independently.
  """

  alias Commerce.Discounts.{Coupon, Rule, DiscountResult, Cart}

  @doc """
  Looks up a coupon by code and validates it is usable by the given customer.
  """
  @spec fetch_coupon(String.t(), String.t(), module()) ::
          {:ok, Coupon.t()} | {:error, String.t()}
  def fetch_coupon(code, customer_id, store)
      when is_binary(code) and is_binary(customer_id) and is_atom(store) do
    with {:ok, coupon} <- store.get_by_code(code),
         :ok <- validate_coupon_usability(coupon, customer_id) do
      {:ok, coupon}
    end
  end

  @doc """
  Applies a coupon's rules to a cart, returning an itemised discount result.
  """
  @spec apply(Coupon.t(), Cart.t()) :: {:ok, DiscountResult.t()} | {:error, String.t()}
  def apply(%Coupon{} = coupon, %Cart{} = cart) do
    with :ok <- check_minimum_order(coupon, cart) do
      discount = evaluate_rules(coupon.rules, cart)
      {:ok, DiscountResult.new(coupon.code, cart, discount)}
    end
  end

  # --- private helpers ---

  defp validate_coupon_usability(%Coupon{status: :active, expires_at: exp}, _customer_id) do
    if expired?(exp), do: {:error, "coupon has expired"}, else: :ok
  end

  defp validate_coupon_usability(%Coupon{status: status}, _),
    do: {:error, "coupon is #{status}"}

  defp check_minimum_order(%Coupon{minimum_order_cents: nil}, _cart), do: :ok

  defp check_minimum_order(%Coupon{minimum_order_cents: min}, %Cart{subtotal_cents: sub})
       when sub >= min, do: :ok

  defp check_minimum_order(%Coupon{minimum_order_cents: min}, _),
    do: {:error, "order does not meet minimum of #{min} cents"}

  defp evaluate_rules(rules, cart) do
    Enum.reduce(rules, 0, fn rule, total ->
      total + Rule.apply(rule, cart)
    end)
  end

  defp expired?(nil), do: false
  defp expired?(exp), do: DateTime.compare(exp, DateTime.utc_now()) == :lt
end

defmodule Commerce.Discounts.Rule do
  @moduledoc "Evaluates a single discount rule against a cart."

  alias Commerce.Discounts.Cart

  @type t :: %{type: :percentage | :fixed | :bogo, value: number(), applies_to: atom()}

  @spec apply(t(), Cart.t()) :: non_neg_integer()
  def apply(%{type: :percentage, value: pct, applies_to: :subtotal}, %Cart{subtotal_cents: sub}) do
    round(sub * pct / 100)
  end

  def apply(%{type: :fixed, value: cents}, _cart) when is_integer(cents) do
    cents
  end

  def apply(%{type: :bogo, applies_to: sku}, %Cart{items: items}) do
    qualifying =
      items
      |> Enum.filter(&(&1.sku == sku))
      |> Enum.map(& &1.unit_price_cents)
      |> Enum.sort(:desc)

    free_count = div(length(qualifying), 2)

    qualifying
    |> Enum.take(free_count)
    |> Enum.sum()
  end

  def apply(_rule, _cart), do: 0
end

defmodule Commerce.Discounts.DiscountResult do
  @moduledoc "Immutable value object summarising a discount application."

  @enforce_keys [:coupon_code, :original_cents, :discount_cents, :final_cents]
  defstruct [:coupon_code, :original_cents, :discount_cents, :final_cents]

  @type t :: %__MODULE__{
          coupon_code: String.t(),
          original_cents: non_neg_integer(),
          discount_cents: non_neg_integer(),
          final_cents: non_neg_integer()
        }

  @spec new(String.t(), Commerce.Discounts.Cart.t(), non_neg_integer()) :: t()
  def new(code, %{subtotal_cents: sub}, discount) do
    %__MODULE__{
      coupon_code: code,
      original_cents: sub,
      discount_cents: discount,
      final_cents: max(sub - discount, 0)
    }
  end
end

defmodule Commerce.Discounts.Cart do
  @moduledoc false

  @enforce_keys [:id, :subtotal_cents, :items]
  defstruct [:id, :subtotal_cents, :items]

  @type item :: %{sku: String.t(), quantity: pos_integer(), unit_price_cents: pos_integer()}
  @type t :: %__MODULE__{id: String.t(), subtotal_cents: non_neg_integer(), items: [item()]}
end

defmodule Commerce.Discounts.Coupon do
  @moduledoc false

  @enforce_keys [:id, :code, :status, :rules]
  defstruct [:id, :code, :status, :rules, :expires_at, :minimum_order_cents]

  @type t :: %__MODULE__{}
end
```
