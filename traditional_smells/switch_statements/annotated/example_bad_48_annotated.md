# Annotated Example — Switch Statements

## Metadata

- **Smell name:** Switch Statements
- **Expected smell location:** `DigestScheduler.cron_expression/1` and `DigestScheduler.frequency_description/1`
- **Affected functions:** `cron_expression/1`, `frequency_description/1`
- **Short explanation:** The same `case` branching over digest frequency (`:realtime`, `:hourly`, `:daily`, `:weekly`) is duplicated in `cron_expression/1` and `frequency_description/1`. Adding a new frequency requires updating both case blocks.

---

```elixir
defmodule DigestScheduler do
  @moduledoc """
  Manages user notification digest preferences and schedules
  digest delivery jobs via a cron-based task runner for an
  event-driven notification platform.
  """

  alias DigestScheduler.{
    UserPreference,
    DigestJob,
    CronRunner,
    PreferenceStore,
    NotificationBatch
  }

  @type digest_frequency :: :realtime | :hourly | :daily | :weekly

  @spec configure_digest(String.t(), digest_frequency()) ::
          {:ok, DigestJob.t()} | {:error, String.t()}
  def configure_digest(user_id, frequency) do
    with {:ok, pref} <- PreferenceStore.upsert(user_id, %{digest_frequency: frequency}),
         cron = cron_expression(frequency),
         {:ok, job} <- CronRunner.register(user_id, cron) do
      {:ok,
       %DigestJob{
         user_id: user_id,
         frequency: frequency,
         cron: cron,
         description: frequency_description(frequency),
         preference_id: pref.id
       }}
    end
  end

  @spec list_user_digest_config(String.t()) :: map()
  def list_user_digest_config(user_id) do
    case PreferenceStore.get(user_id) do
      {:ok, %UserPreference{digest_frequency: freq}} ->
        %{
          user_id: user_id,
          frequency: freq,
          cron: cron_expression(freq),
          description: frequency_description(freq),
          active: true
        }

      {:error, :not_found} ->
        %{user_id: user_id, active: false}
    end
  end

  @spec reschedule_all() :: {:ok, integer()}
  def reschedule_all do
    {:ok, all_prefs} = PreferenceStore.list_all()

    count =
      Enum.reduce(all_prefs, 0, fn pref, acc ->
        cron = cron_expression(pref.digest_frequency)

        case CronRunner.update(pref.user_id, cron) do
          :ok -> acc + 1
          {:error, _} -> acc
        end
      end)

    {:ok, count}
  end

  @spec deliver_pending_digests(digest_frequency()) :: {:ok, integer()}
  def deliver_pending_digests(frequency) do
    {:ok, user_ids} = PreferenceStore.users_with_frequency(frequency)

    delivered =
      Enum.count(user_ids, fn user_id ->
        case NotificationBatch.build_and_send(user_id, frequency) do
          {:ok, _} -> true
          _ -> false
        end
      end)

    {:ok, delivered}
  end

  # VALIDATION: SMELL START - Switch Statements
  # VALIDATION: This is a smell because the same case branching on `frequency`
  # also appears in `frequency_description/1` below. Both enumerate :realtime,
  # :hourly, :daily, :weekly — adding a new frequency requires updating both.
  @spec cron_expression(digest_frequency()) :: String.t()
  def cron_expression(frequency) do
    case frequency do
      :realtime -> "* * * * *"
      :hourly   -> "0 * * * *"
      :daily    -> "0 8 * * *"
      :weekly   -> "0 8 * * 1"
    end
  end
  # VALIDATION: SMELL END

  # VALIDATION: SMELL START - Switch Statements
  # VALIDATION: This is a smell because the same case branching on `frequency`
  # already appeared in `cron_expression/1` above. The frequency atoms are
  # fully repeated, so any new frequency must be added in both case blocks.
  @spec frequency_description(digest_frequency()) :: String.t()
  def frequency_description(frequency) do
    case frequency do
      :realtime -> "As events happen"
      :hourly   -> "Once per hour"
      :daily    -> "Every day at 8:00 AM"
      :weekly   -> "Every Monday at 8:00 AM"
    end
  end
  # VALIDATION: SMELL END

  @spec valid_frequency?(atom()) :: boolean()
  def valid_frequency?(freq), do: freq in [:realtime, :hourly, :daily, :weekly]

  @spec unsubscribe(String.t()) :: :ok | {:error, term()}
  def unsubscribe(user_id) do
    with :ok <- CronRunner.deregister(user_id),
         :ok <- PreferenceStore.delete(user_id) do
      :ok
    end
  end
end
```
