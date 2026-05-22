# Annotated Bad Example 24

**Smell:** "Use" instead of "import"
**Expected Smell Location:** `Orders.OrderManager`, `use Orders.StatusHelpers` directive
**Affected Functions:** `place/1`, `cancel/2`, `mark_shipped/2`, `mark_delivered/1`, `history/1`
**Explanation:** `Orders.OrderManager` uses `use Orders.StatusHelpers` to access status-transition predicates and label helpers. However, `StatusHelpers.__using__/1` silently injects an alias for `Orders.NotificationService` and sets `@cancellation_window_hours` and `@max_items_per_order` module attributes. These propagated dependencies are invisible to a reader of `OrderManager` who has not inspected the library macro. A plain `import Orders.StatusHelpers` would expose only the predicates the module needs without hiding additional aliases and module attributes.

```elixir
defmodule Orders.StatusHelpers do
  @moduledoc """
  Pure predicate and label functions for order status management.
  Contains no side-effects or I/O.
  """

  def valid_transition?(:pending,    :confirmed),  do: true
  def valid_transition?(:confirmed,  :processing), do: true
  def valid_transition?(:processing, :shipped),    do: true
  def valid_transition?(:shipped,    :delivered),  do: true
  def valid_transition?(:pending,    :cancelled),  do: true
  def valid_transition?(:confirmed,  :cancelled),  do: true
  def valid_transition?(_,           _),           do: false

  def cancellable?(:pending),   do: true
  def cancellable?(:confirmed), do: true
  def cancellable?(_),          do: false

  def status_label(:pending),    do: "Awaiting Confirmation"
  def status_label(:confirmed),  do: "Confirmed"
  def status_label(:processing), do: "Being Processed"
  def status_label(:shipped),    do: "Shipped"
  def status_label(:delivered),  do: "Delivered"
  def status_label(:cancelled),  do: "Cancelled"
  def status_label(_),           do: "Unknown"

  def terminal?(:delivered),  do: true
  def terminal?(:cancelled),  do: true
  def terminal?(_),           do: false

  # VALIDATION: SMELL START - "Use" instead of "import"
  # VALIDATION: This is a smell because __using__/1 propagates alias
  # Orders.NotificationService and two module attributes into calling modules.
  # The caller never asked for NotificationService as a dependency; it is
  # injected silently by the macro expansion of `use Orders.StatusHelpers`.
  defmacro __using__(_opts) do
    quote do
      import Orders.StatusHelpers
      alias Orders.NotificationService

      @cancellation_window_hours 24
      @max_items_per_order       50
    end
  end
  # VALIDATION: SMELL END - "Use" instead of "import"
end

defmodule Orders.NotificationService do
  @moduledoc "Dispatches transactional notifications for order lifecycle events (stub)."

  def notify_confirmed(order),   do: IO.puts("[Notify] Order #{order.id} confirmed for user #{order.user_id}")
  def notify_shipped(order),     do: IO.puts("[Notify] Order #{order.id} shipped — tracking: #{order.tracking_number}")
  def notify_delivered(order),   do: IO.puts("[Notify] Order #{order.id} delivered to #{order.user_id}")
  def notify_cancelled(order, reason), do: IO.puts("[Notify] Order #{order.id} cancelled: #{reason}")
end

defmodule Orders.OrderManager do
  # VALIDATION: SMELL START - "Use" instead of "import"
  # VALIDATION: This is a smell because `use Orders.StatusHelpers` expands
  # __using__/1, silently injecting alias Orders.NotificationService and the
  # module attributes @cancellation_window_hours and @max_items_per_order.
  # A reader of OrderManager sees no explicit declaration of these dependencies;
  # they are hidden inside the library macro. `import Orders.StatusHelpers`
  # would have made only the predicate functions available.
  use Orders.StatusHelpers
  # VALIDATION: SMELL END - "Use" instead of "import"

  @moduledoc """
  Manages the order lifecycle: placement, confirmation, fulfilment, and cancellation.
  Integrates with the notification service for customer-facing updates.
  """

  defstruct [
    :id, :user_id, :items, :status,
    :total_cents, :tracking_number,
    :placed_at, :updated_at
  ]

  def place(%{user_id: uid, items: items} = params) do
    cond do
      length(items) == 0 ->
        {:error, :no_items}

      length(items) > @max_items_per_order ->
        {:error, {:too_many_items, @max_items_per_order}}

      true ->
        order = %__MODULE__{
          id:          generate_id(),
          user_id:     uid,
          items:       items,
          status:      :pending,
          total_cents: compute_total(items),
          placed_at:   DateTime.utc_now(),
          updated_at:  DateTime.utc_now()
        }
        {:ok, order}
    end
  end

  def confirm(%__MODULE__{status: :pending} = order) do
    updated = %{order | status: :confirmed, updated_at: DateTime.utc_now()}
    NotificationService.notify_confirmed(updated)
    {:ok, updated}
  end

  def confirm(%__MODULE__{status: s}), do: {:error, "Cannot confirm order with status #{s}"}

  def cancel(%__MODULE__{} = order, reason) do
    hours_since = DateTime.diff(DateTime.utc_now(), order.placed_at, :second) / 3600

    cond do
      not cancellable?(order.status) ->
        {:error, "Status #{order.status} cannot be cancelled"}

      hours_since > @cancellation_window_hours ->
        {:error, :cancellation_window_expired}

      true ->
        updated = %{order | status: :cancelled, updated_at: DateTime.utc_now()}
        NotificationService.notify_cancelled(updated, reason)
        {:ok, updated}
    end
  end

  def mark_shipped(%__MODULE__{status: :processing} = order, tracking_number) do
    updated = %{order | status: :shipped, tracking_number: tracking_number, updated_at: DateTime.utc_now()}
    NotificationService.notify_shipped(updated)
    {:ok, updated}
  end

  def mark_shipped(%__MODULE__{status: s}, _), do: {:error, "Cannot ship from status #{s}"}

  def mark_delivered(%__MODULE__{status: :shipped} = order) do
    updated = %{order | status: :delivered, updated_at: DateTime.utc_now()}
    NotificationService.notify_delivered(updated)
    {:ok, updated}
  end

  def mark_delivered(%__MODULE__{status: s}), do: {:error, "Cannot deliver from status #{s}"}

  def history(%__MODULE__{} = order) do
    %{
      id:          order.id,
      user_id:     order.user_id,
      status:      status_label(order.status),
      terminal:    terminal?(order.status),
      total_cents: order.total_cents,
      placed_at:   order.placed_at
    }
  end

  defp compute_total(items) do
    Enum.reduce(items, 0, fn item, acc -> acc + item[:price_cents] * (item[:quantity] || 1) end)
  end

  defp generate_id, do: "ORD-" <> Base.encode16(:crypto.strong_rand_bytes(5), case: :upper)
end
```
