# Code Smell Annotation

- **Smell name:** Comments
- **Expected smell location:** `NotificationDispatcher` module, function `dispatch/2`
- **Affected function(s):** `dispatch/2`
- **Short explanation:** The function `dispatch/2` is documented with plain `#` comments instead of `@doc`, making the documentation inaccessible through ExDoc or IEx.

```elixir
defmodule NotificationDispatcher do
  @moduledoc """
  Routes outbound notifications to the appropriate delivery channel based on
  user preferences and notification type.
  """

  alias NotificationDispatcher.{Channel, Preference, Template}
  require Logger

  @supported_channels [:email, :sms, :push, :webhook]
  @default_retry_count 3

  @doc """
  Loads notification preferences for a given user ID from the preference store.
  Returns `{:ok, preferences}` or `{:error, :not_found}`.
  """
  def load_preferences(user_id) when is_binary(user_id) do
    Preference.fetch(user_id)
  end

  @doc """
  Renders a notification template for the given event type and context map.
  """
  def render_template(event_type, context) when is_atom(event_type) and is_map(context) do
    Template.render(event_type, context)
  end

  # VALIDATION: SMELL START - Comments
  # VALIDATION: This is a smell because `dispatch/2` relies on `#` comments for documentation
  # VALIDATION: instead of `@doc`. These comments are invisible to the Elixir toolchain
  # VALIDATION: and cannot be looked up at runtime or compiled into documentation.

  # Dispatches a notification to a user through one or more channels.
  #
  # Parameters:
  #   notification - a map with keys:
  #     :user_id   - the target user's identifier (string)
  #     :event     - atom representing the event type (e.g. :password_reset)
  #     :context   - map of dynamic values to inject into the template
  #     :channels  - (optional) list of channel atoms to override user preferences
  #   opts - keyword list:
  #     :retries   - number of retry attempts on failure (default: 3)
  #     :priority  - :high | :normal | :low (default: :normal)
  #
  # Returns :ok if at least one channel succeeded, {:error, errors} otherwise.
  def dispatch(%{user_id: user_id, event: event, context: context} = notification, opts \\ []) do
    retries = Keyword.get(opts, :retries, @default_retry_count)
    priority = Keyword.get(opts, :priority, :normal)

    channels =
      Map.get_lazy(notification, :channels, fn ->
        case load_preferences(user_id) do
          {:ok, prefs} -> prefs.enabled_channels
          _ -> [:email]
        end
      end)

    channels
    |> Enum.filter(&(&1 in @supported_channels))
    |> Enum.map(fn channel ->
      with {:ok, body} <- render_template(event, context),
           :ok <- Channel.send(channel, user_id, body, retries: retries, priority: priority) do
        {:ok, channel}
      else
        {:error, reason} ->
          Logger.warning("Dispatch failed on #{channel} for user #{user_id}: #{inspect(reason)}")
          {:error, {channel, reason}}
      end
    end)
    |> collect_results()
  end

  # VALIDATION: SMELL END

  @doc """
  Schedules a notification for future delivery at the given UTC datetime.
  """
  def schedule(%{user_id: _} = notification, %DateTime{} = deliver_at) do
    delay_ms = DateTime.diff(deliver_at, DateTime.utc_now(), :millisecond)

    if delay_ms > 0 do
      Process.send_after(self(), {:dispatch, notification}, delay_ms)
      {:ok, :scheduled}
    else
      dispatch(notification)
    end
  end

  @doc """
  Handles the deferred `:dispatch` message sent by `schedule/2`.
  """
  def handle_info({:dispatch, notification}, state) do
    dispatch(notification)
    {:noreply, state}
  end

  defp collect_results(results) do
    errors = Enum.filter(results, &match?({:error, _}, &1))

    case errors do
      [] -> :ok
      _ -> {:error, Enum.map(errors, fn {:error, e} -> e end)}
    end
  end
end
```
