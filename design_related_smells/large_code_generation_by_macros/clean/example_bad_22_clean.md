```elixir
defmodule MyApp.Notifications.ChannelRegistry do
  @moduledoc """
  DSL for registering notification delivery channels on a notifier module.

  Example:

      defmodule MyApp.Notifications.OrderNotifier do
        use MyApp.Notifications.ChannelRegistry

        notify_via MyApp.Channels.Email,  priority: :high,  retry: 3
        notify_via MyApp.Channels.SMS,    priority: :low,   retry: 1
        notify_via MyApp.Channels.Push,   priority: :medium
      end
  """

  defmacro __using__(_opts) do
    quote do
      import MyApp.Notifications.ChannelRegistry, only: [notify_via: 2]
      Module.register_attribute(__MODULE__, :notification_channels, accumulate: true)
      @before_compile MyApp.Notifications.ChannelRegistry
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      def channels, do: @notification_channels

      def deliver(event, payload) do
        MyApp.Notifications.ChannelRegistry.dispatch(
          __MODULE__.channels(),
          event,
          payload
        )
      end
    end
  end

  defmacro notify_via(channel_module, opts \\ []) do
    quote do
      channel_module = unquote(channel_module)
      opts           = unquote(opts)

      unless is_atom(channel_module) do
        raise ArgumentError,
              "notify_via/2: channel module must be an atom, got #{inspect(channel_module)}"
      end

      :ok = Code.ensure_compiled!(channel_module)

      unless function_exported?(channel_module, :deliver, 2) do
        raise ArgumentError,
              "notify_via/2: #{inspect(channel_module)} must export deliver/2"
      end

      unless function_exported?(channel_module, :supported_events, 0) do
        raise ArgumentError,
              "notify_via/2: #{inspect(channel_module)} must export supported_events/0"
      end

      valid_priorities = [:low, :medium, :high, :critical]
      priority = Keyword.get(opts, :priority, :medium)

      unless priority in valid_priorities do
        raise ArgumentError,
              "notify_via/2: :priority must be one of #{inspect(valid_priorities)}, " <>
                "got #{inspect(priority)}"
      end

      retry = Keyword.get(opts, :retry, 0)

      unless is_integer(retry) and retry >= 0 and retry <= 10 do
        raise ArgumentError,
              "notify_via/2: :retry must be an integer between 0 and 10, " <>
                "got #{inspect(retry)}"
      end

      timeout_ms = Keyword.get(opts, :timeout_ms, 5_000)

      unless is_integer(timeout_ms) and timeout_ms > 0 do
        raise ArgumentError,
              "notify_via/2: :timeout_ms must be a positive integer, " <>
                "got #{inspect(timeout_ms)}"
      end

      existing = Module.get_attribute(__MODULE__, :notification_channels)

      if Enum.any?(existing, fn ch -> ch.module == channel_module end) do
        raise ArgumentError,
              "notify_via/2: #{inspect(channel_module)} is already registered " <>
                "in #{inspect(__MODULE__)}"
      end

      channel = %{
        module:     channel_module,
        priority:   priority,
        retry:      retry,
        timeout_ms: timeout_ms,
        extra_opts: Keyword.drop(opts, [:priority, :retry, :timeout_ms])
      }

      @notification_channels channel
    end
  end

  @doc false
  def dispatch(channels, event, payload) do
    channels
    |> Enum.sort_by(fn ch ->
      %{critical: 0, high: 1, medium: 2, low: 3}[ch.priority]
    end)
    |> Enum.each(fn ch ->
      attempt_delivery(ch, event, payload, ch.retry)
    end)
  end

  defp attempt_delivery(_ch, _event, _payload, retries_left) when retries_left < 0, do: :ok
  defp attempt_delivery(ch, event, payload, retries_left) do
    case ch.module.deliver(event, payload) do
      :ok ->
        :ok

      {:error, reason} ->
        require Logger
        Logger.warning("[ChannelRegistry] Delivery failed via #{inspect(ch.module)}: #{inspect(reason)}")
        attempt_delivery(ch, event, payload, retries_left - 1)
    end
  end
end
```
