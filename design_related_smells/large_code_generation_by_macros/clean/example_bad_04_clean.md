```elixir
defmodule Notifications.ChannelDSL do
  @moduledoc """
  Compile-time DSL for declaring notification channels.

  A channel bundles a delivery adapter, retry policy, timeout,
  and priority level. Channels are registered at compile time so
  the dispatcher can resolve them without runtime lookups.
  """

  defmacro defchannel(channel_name, opts) do
    quote do
      channel = unquote(channel_name)
      opts    = unquote(opts)

      unless is_atom(channel) do
        raise ArgumentError,
              "channel name must be an atom, got: #{inspect(channel)}"
      end

      adapter = Keyword.fetch!(opts, :adapter)

      unless is_atom(adapter) do
        raise ArgumentError,
              "channel #{inspect(channel)} :adapter must be a module atom"
      end

      template_key = Keyword.fetch!(opts, :template_key)

      unless is_binary(template_key) do
        raise ArgumentError,
              "channel #{inspect(channel)} :template_key must be a binary"
      end

      max_retries = Keyword.get(opts, :max_retries, 3)

      unless is_integer(max_retries) and max_retries >= 0 do
        raise ArgumentError,
              "channel #{inspect(channel)} :max_retries must be a non-negative integer"
      end

      retry_backoff = Keyword.get(opts, :retry_backoff, :exponential)

      unless retry_backoff in [:linear, :exponential, :none] do
        raise ArgumentError,
              "channel #{inspect(channel)} :retry_backoff must be :linear, :exponential, or :none"
      end

      timeout_ms = Keyword.get(opts, :timeout_ms, 5_000)

      unless is_integer(timeout_ms) and timeout_ms > 0 do
        raise ArgumentError,
              "channel #{inspect(channel)} :timeout_ms must be a positive integer"
      end

      priority = Keyword.get(opts, :priority, :normal)

      unless priority in [:low, :normal, :high, :critical] do
        raise ArgumentError,
              "channel #{inspect(channel)} :priority must be :low, :normal, :high, or :critical"
      end

      enabled = Keyword.get(opts, :enabled, true)

      unless is_boolean(enabled) do
        raise ArgumentError,
              "channel #{inspect(channel)} :enabled must be a boolean"
      end

      @notification_channels %{
        name:          channel,
        adapter:       adapter,
        template_key:  template_key,
        max_retries:   max_retries,
        retry_backoff: retry_backoff,
        timeout_ms:    timeout_ms,
        priority:      priority,
        enabled:       enabled
      }
    end
  end

  defmacro __using__(_) do
    quote do
      import Notifications.ChannelDSL, only: [defchannel: 2]
      Module.register_attribute(__MODULE__, :notification_channels, accumulate: true)
      @before_compile Notifications.ChannelDSL
    end
  end

  defmacro __before_compile__(env) do
    channels = Module.get_attribute(env.module, :notification_channels)

    quote do
      def channels, do: unquote(Macro.escape(channels))

      def channel(name) do
        Enum.find(channels(), &(&1.name == name))
      end

      def enabled_channels do
        Enum.filter(channels(), & &1.enabled)
      end
    end
  end
end

defmodule Notifications.AppChannels do
  use Notifications.ChannelDSL

  defchannel(:email_transactional,
    adapter: Notifications.Adapters.Sendgrid,
    template_key: "transactional_v2",
    max_retries: 5,
    retry_backoff: :exponential,
    timeout_ms: 8_000,
    priority: :high,
    enabled: true
  )

  defchannel(:email_marketing,
    adapter: Notifications.Adapters.Sendgrid,
    template_key: "marketing_v1",
    max_retries: 2,
    retry_backoff: :linear,
    timeout_ms: 10_000,
    priority: :low,
    enabled: true
  )

  defchannel(:sms_otp,
    adapter: Notifications.Adapters.Twilio,
    template_key: "otp_sms",
    max_retries: 3,
    retry_backoff: :exponential,
    timeout_ms: 4_000,
    priority: :critical,
    enabled: true
  )

  defchannel(:push_mobile,
    adapter: Notifications.Adapters.Firebase,
    template_key: "push_default",
    max_retries: 3,
    retry_backoff: :exponential,
    timeout_ms: 5_000,
    priority: :normal,
    enabled: true
  )

  defchannel(:webhook_partner,
    adapter: Notifications.Adapters.Webhook,
    template_key: "webhook_v1",
    max_retries: 10,
    retry_backoff: :exponential,
    timeout_ms: 15_000,
    priority: :normal,
    enabled: false
  )

  defchannel(:slack_ops,
    adapter: Notifications.Adapters.Slack,
    template_key: "ops_alert",
    max_retries: 2,
    retry_backoff: :none,
    timeout_ms: 3_000,
    priority: :high,
    enabled: true
  )
end
```
