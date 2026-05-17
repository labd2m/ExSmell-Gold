# Annotated Example 04 — Modules with Identical Names

## Metadata

- **Smell name:** Modules with Identical Names
- **Expected smell location:** Two separate files both define `Notifications.Dispatcher`
- **Affected functions:** `Notifications.Dispatcher.dispatch/2` (file one) and `Notifications.Dispatcher.batch_dispatch/2` (file two)
- **Explanation:** `Notifications.Dispatcher` is defined in both `lib/notifications/dispatcher.ex` and `lib/notifications/batch_dispatcher.ex`. BEAM will overwrite the first with the second on compilation. Any caller relying on `dispatch/2` from the first file will get an `UndefinedFunctionError` if that file is compiled first.

---

```elixir
# ── file: lib/notifications/dispatcher.ex ────────────────────────────────────

defmodule Notifications.Dispatcher do
  @moduledoc """
  Routes individual notification payloads to the correct delivery channel
  (email, SMS, push, or in-app). Used by domain event handlers.
  """

  alias Notifications.{
    Channels.Email,
    Channels.SMS,
    Channels.Push,
    Channels.InApp,
    RateLimit,
    Preference
  }

  @supported_channels [:email, :sms, :push, :in_app]

  @type payload :: %{
          recipient_id: String.t(),
          template: atom(),
          params: map(),
          channel: atom()
        }

  # VALIDATION: SMELL START - Modules with Identical Names
  # VALIDATION: This is a smell because `Notifications.Dispatcher` is declared
  # again in `lib/notifications/batch_dispatcher.ex`. Only one version survives
  # in BEAM. `dispatch/2` may become permanently unreachable at runtime.

  @spec dispatch(payload(), keyword()) :: :ok | {:error, term()}
  def dispatch(%{channel: channel} = payload, opts \\ []) do
    with :ok <- validate_channel(channel),
         :ok <- check_preferences(payload.recipient_id, channel),
         :ok <- RateLimit.check(payload.recipient_id, channel) do
      deliver(channel, payload, opts)
    end
  end

  # VALIDATION: SMELL END

  @spec supported_channels() :: [atom()]
  def supported_channels, do: @supported_channels

  defp validate_channel(channel) when channel in @supported_channels, do: :ok
  defp validate_channel(ch), do: {:error, {:unsupported_channel, ch}}

  defp check_preferences(recipient_id, channel) do
    case Preference.lookup(recipient_id, channel) do
      {:ok, %{enabled: true}} -> :ok
      {:ok, %{enabled: false}} -> {:error, :channel_disabled_by_user}
      {:error, _} -> :ok
    end
  end

  defp deliver(:email, payload, opts) do
    Email.send(%{
      to: payload.recipient_id,
      template: payload.template,
      params: payload.params,
      priority: Keyword.get(opts, :priority, :normal)
    })
  end

  defp deliver(:sms, payload, _opts) do
    SMS.send(%{
      to: payload.recipient_id,
      template: payload.template,
      params: payload.params
    })
  end

  defp deliver(:push, payload, opts) do
    Push.send(%{
      recipient_id: payload.recipient_id,
      template: payload.template,
      params: payload.params,
      ttl: Keyword.get(opts, :ttl, 3_600)
    })
  end

  defp deliver(:in_app, payload, _opts) do
    InApp.insert(%{
      recipient_id: payload.recipient_id,
      template: payload.template,
      params: payload.params,
      read: false,
      created_at: DateTime.utc_now()
    })
  end
end


# ── file: lib/notifications/batch_dispatcher.ex ──────────────────────────────

defmodule Notifications.Dispatcher do
  @moduledoc """
  Handles bulk notification dispatch for marketing campaigns, system alerts,
  and scheduled digest emails. Processes recipients in chunked batches.
  """

  alias Notifications.{Channels.Email, Channels.Push, RateLimit}

  @batch_size 100
  @inter_batch_delay_ms 200

  @type batch_payload :: %{
          template: atom(),
          params: map(),
          channel: atom()
        }

  @spec batch_dispatch([String.t()], batch_payload()) :: %{
          sent: non_neg_integer(),
          failed: non_neg_integer(),
          skipped: non_neg_integer()
        }
  def batch_dispatch(recipient_ids, payload) when is_list(recipient_ids) do
    recipient_ids
    |> Enum.chunk_every(@batch_size)
    |> Enum.reduce(%{sent: 0, failed: 0, skipped: 0}, fn chunk, acc ->
      results = deliver_chunk(chunk, payload)
      Process.sleep(@inter_batch_delay_ms)

      %{
        sent: acc.sent + results.sent,
        failed: acc.failed + results.failed,
        skipped: acc.skipped + results.skipped
      }
    end)
  end

  @spec schedule_batch([String.t()], batch_payload(), DateTime.t()) ::
          {:ok, String.t()} | {:error, term()}
  def schedule_batch(recipient_ids, payload, send_at) do
    job_id = generate_job_id()

    RateLimit.reserve_bulk(length(recipient_ids), payload.channel)

    {:ok,
     %{
       job_id: job_id,
       recipient_count: length(recipient_ids),
       payload: payload,
       send_at: send_at,
       status: :scheduled
     }}
  end

  defp deliver_chunk(recipient_ids, %{channel: :email} = payload) do
    results =
      Enum.map(recipient_ids, fn id ->
        Email.send(%{to: id, template: payload.template, params: payload.params})
      end)

    tally(results)
  end

  defp deliver_chunk(recipient_ids, %{channel: :push} = payload) do
    results =
      Enum.map(recipient_ids, fn id ->
        Push.send(%{recipient_id: id, template: payload.template, params: payload.params})
      end)

    tally(results)
  end

  defp deliver_chunk(_, _), do: %{sent: 0, failed: 0, skipped: 0}

  defp tally(results) do
    Enum.reduce(results, %{sent: 0, failed: 0, skipped: 0}, fn
      :ok, acc -> %{acc | sent: acc.sent + 1}
      {:error, :skipped}, acc -> %{acc | skipped: acc.skipped + 1}
      {:error, _}, acc -> %{acc | failed: acc.failed + 1}
    end)
  end

  defp generate_job_id do
    "BATCH-" <> (:crypto.strong_rand_bytes(6) |> Base.encode16())
  end
end
```
