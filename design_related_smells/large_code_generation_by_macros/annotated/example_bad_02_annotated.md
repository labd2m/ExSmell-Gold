# Annotated Example 02 — Large Code Generation by Macros

## Metadata

- **Smell name:** Large code generation by macros
- **Expected smell location:** `defmacro defstatus/2` inside `Logistics.StatusRegistry`
- **Affected function(s):** `defstatus/2`
- **Short explanation:** The macro inlines a full block of guards, transition validation, notification dispatch logic, and module attribute writes on every call. Each invocation causes the compiler to emit and compile that entire code body again, instead of delegating it to a helper function.

---

```elixir
defmodule Logistics.StatusRegistry do
  @moduledoc """
  Compile-time DSL for registering shipment statuses, their allowed
  transitions, and the notification channels that must be triggered
  when a shipment enters each status.
  """

  @doc """
  Registers a shipment status with its metadata and transition rules.
  """

  # VALIDATION: SMELL START - Large code generation by macros
  # VALIDATION: This is a smell because every call to defstatus/2 causes
  # VALIDATION: the compiler to expand all the validation, transition-check,
  # VALIDATION: and notification-routing logic inline. The bulk of this work
  # VALIDATION: should be moved into a plain function to avoid repeated
  # VALIDATION: code expansion at every call site.
  defmacro defstatus(status_name, opts \\ []) do
    quote do
      status = unquote(status_name)
      opts   = unquote(opts)

      unless is_atom(status) do
        raise ArgumentError,
              "status name must be an atom, got: #{inspect(status)}"
      end

      label = Keyword.fetch!(opts, :label)

      unless is_binary(label) do
        raise ArgumentError,
              "status #{inspect(status)} requires a binary :label"
      end

      next_states = Keyword.get(opts, :next, [])

      unless is_list(next_states) and Enum.all?(next_states, &is_atom/1) do
        raise ArgumentError,
              "status #{inspect(status)} :next must be a list of atoms"
      end

      notify_channels = Keyword.get(opts, :notify, [])

      unless is_list(notify_channels) do
        raise ArgumentError,
              "status #{inspect(status)} :notify must be a list"
      end

      valid_channels = [:email, :sms, :push, :webhook]

      Enum.each(notify_channels, fn ch ->
        unless ch in valid_channels do
          raise ArgumentError,
                "invalid channel #{inspect(ch)} for status #{inspect(status)}. " <>
                  "Valid channels: #{inspect(valid_channels)}"
        end
      end)

      terminal = Keyword.get(opts, :terminal, false)

      unless is_boolean(terminal) do
        raise ArgumentError,
              "status #{inspect(status)} :terminal must be a boolean"
      end

      requires_signature = Keyword.get(opts, :requires_signature, false)

      unless is_boolean(requires_signature) do
        raise ArgumentError,
              "status #{inspect(status)} :requires_signature must be a boolean"
      end

      @registered_statuses %{
        name: status,
        label: label,
        next: next_states,
        notify: notify_channels,
        terminal: terminal,
        requires_signature: requires_signature
      }
    end
  end
  # VALIDATION: SMELL END

  defmacro __using__(_) do
    quote do
      import Logistics.StatusRegistry, only: [defstatus: 1, defstatus: 2]
      Module.register_attribute(__MODULE__, :registered_statuses, accumulate: true)
      @before_compile Logistics.StatusRegistry
    end
  end

  defmacro __before_compile__(env) do
    statuses = Module.get_attribute(env.module, :registered_statuses)

    quote do
      def statuses, do: unquote(Macro.escape(statuses))

      def can_transition?(from, to) do
        case Enum.find(statuses(), &(&1.name == from)) do
          nil -> false
          st  -> to in st.next
        end
      end

      def notification_channels(status) do
        case Enum.find(statuses(), &(&1.name == status)) do
          nil -> []
          st  -> st.notify
        end
      end
    end
  end
end

defmodule Logistics.ShipmentStatuses do
  use Logistics.StatusRegistry

  defstatus(:created,
    label: "Created",
    next: [:picked_up, :cancelled],
    notify: [:email],
    terminal: false
  )

  defstatus(:picked_up,
    label: "Picked Up",
    next: [:in_transit, :exception],
    notify: [:email, :sms],
    terminal: false
  )

  defstatus(:in_transit,
    label: "In Transit",
    next: [:out_for_delivery, :exception],
    notify: [:push],
    terminal: false
  )

  defstatus(:out_for_delivery,
    label: "Out for Delivery",
    next: [:delivered, :exception],
    notify: [:push, :sms],
    terminal: false
  )

  defstatus(:delivered,
    label: "Delivered",
    next: [],
    notify: [:email, :sms, :push],
    terminal: true,
    requires_signature: true
  )

  defstatus(:exception,
    label: "Exception",
    next: [:in_transit, :returned, :cancelled],
    notify: [:email, :sms, :webhook],
    terminal: false
  )

  defstatus(:cancelled,
    label: "Cancelled",
    next: [],
    notify: [:email],
    terminal: true
  )

  defstatus(:returned,
    label: "Returned to Sender",
    next: [],
    notify: [:email, :webhook],
    terminal: true
  )
end
```
