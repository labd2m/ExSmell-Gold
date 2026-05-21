# Annotated Example — Bad Code

## Metadata

- **Smell name:** Large code generation by macros
- **Expected smell location:** `defmacro webhook/3` inside `MyApp.Webhooks.DispatcherDSL`
- **Affected function(s):** `webhook/3` macro
- **Short explanation:** Every call to `webhook/3` expands a large `quote` block that validates the event name, URL format, signing secret option, retry strategy, timeout, header map, and deduplication — completely inline at the call site. With many webhooks declared in a single dispatcher module, this generates a large amount of repeated compiled code that should instead be delegated to a helper function.

---

```elixir
defmodule MyApp.Webhooks.DispatcherDSL do
  @moduledoc """
  DSL for declaring outbound webhook endpoints in a dispatcher module.

  Example:

      defmodule MyApp.Webhooks.OrderDispatcher do
        use MyApp.Webhooks.DispatcherDSL

        webhook :order_placed, "https://partner.example.com/hooks/orders",
          secret:      "whsec_abc123",
          retry:       3,
          timeout_ms:  5_000,
          headers:     %{"X-Source" => "acme"}

        webhook :order_shipped, "https://partner.example.com/hooks/shipments",
          secret:     "whsec_xyz789",
          retry:      2,
          timeout_ms: 4_000

        webhook :order_refunded, "https://finance.partner.com/hooks/refunds",
          retry:      5,
          timeout_ms: 8_000,
          headers:    %{"X-Source" => "acme", "X-Priority" => "high"}
      end
  """

  defmacro __using__(_opts) do
    quote do
      import MyApp.Webhooks.DispatcherDSL, only: [webhook: 3]
      Module.register_attribute(__MODULE__, :webhooks, accumulate: true)
      @before_compile MyApp.Webhooks.DispatcherDSL
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      def webhooks, do: @webhooks

      def webhooks_for(event) do
        Enum.filter(@webhooks, fn w -> w.event == event end)
      end
    end
  end

  # VALIDATION: SMELL START - Large code generation by macros
  # VALIDATION: This is a smell because every call to webhook/3 expands this
  # VALIDATION: entire block inline at the call site: event-name atom check,
  # VALIDATION: URL binary-and-scheme check, secret string check, retry integer
  # VALIDATION: range check, timeout integer check, headers map check, key/value
  # VALIDATION: type checks on headers entries, deduplication guard, and webhook
  # VALIDATION: struct construction. Each of the N webhook declarations compiles
  # VALIDATION: all of this code independently instead of delegating to a
  # VALIDATION: shared function.
  defmacro webhook(event, url, opts \\ []) do
    quote do
      event = unquote(event)
      url   = unquote(url)
      opts  = unquote(opts)

      unless is_atom(event) do
        raise ArgumentError,
              "webhook/3: event must be an atom, got #{inspect(event)}"
      end

      unless is_binary(url) and
               (String.starts_with?(url, "https://") or String.starts_with?(url, "http://")) do
        raise ArgumentError,
              "webhook/3: url must be a binary starting with http(s)://, got #{inspect(url)}"
      end

      secret = Keyword.get(opts, :secret)

      if not is_nil(secret) do
        unless is_binary(secret) and byte_size(secret) >= 8 do
          raise ArgumentError,
                "webhook/3: :secret must be at least 8 characters, got #{inspect(secret)}"
        end
      end

      retry = Keyword.get(opts, :retry, 0)

      unless is_integer(retry) and retry >= 0 and retry <= 10 do
        raise ArgumentError,
              "webhook/3: :retry must be an integer in [0, 10], got #{inspect(retry)}"
      end

      timeout_ms = Keyword.get(opts, :timeout_ms, 5_000)

      unless is_integer(timeout_ms) and timeout_ms > 0 do
        raise ArgumentError,
              "webhook/3: :timeout_ms must be a positive integer, got #{inspect(timeout_ms)}"
      end

      headers = Keyword.get(opts, :headers, %{})

      unless is_map(headers) do
        raise ArgumentError,
              "webhook/3: :headers must be a map, got #{inspect(headers)}"
      end

      unless Enum.all?(headers, fn {k, v} -> is_binary(k) and is_binary(v) end) do
        raise ArgumentError,
              "webhook/3: all header keys and values must be strings in #{inspect(headers)}"
      end

      existing = Module.get_attribute(__MODULE__, :webhooks)

      if Enum.any?(existing, fn w -> w.event == event and w.url == url end) do
        raise ArgumentError,
              "webhook/3: duplicate registration for event #{inspect(event)} => " <>
                "#{inspect(url)} in #{inspect(__MODULE__)}"
      end

      wh = %{
        event:      event,
        url:        url,
        secret:     secret,
        retry:      retry,
        timeout_ms: timeout_ms,
        headers:    headers
      }

      @webhooks wh
    end
  end
  # VALIDATION: SMELL END

  @doc """
  Dispatches a webhook payload for the given event to all registered endpoints.
  Signing is applied when a :secret is configured.
  """
  @spec dispatch(module(), atom(), map()) :: [{String.t(), :ok | {:error, any()}}]
  def dispatch(dispatcher_module, event, payload) do
    dispatcher_module.webhooks_for(event)
    |> Enum.map(fn wh ->
      body        = Jason.encode!(payload)
      sig_headers = maybe_sign(wh.secret, body)
      all_headers = Map.merge(wh.headers, sig_headers)

      result = MyApp.Webhooks.HTTP.post(wh.url, body, all_headers,
                                        timeout: wh.timeout_ms,
                                        retry:   wh.retry)
      {wh.url, result}
    end)
  end

  defp maybe_sign(nil, _body), do: %{}
  defp maybe_sign(secret, body) do
    hmac = :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)
    %{"X-Webhook-Signature" => "sha256=#{hmac}"}
  end
end
```
