```elixir
defmodule MyApp.Ecommerce.CartRecovery do
  @moduledoc """
  Identifies abandoned carts and schedules recovery email sequences.
  A cart is considered abandoned when it has not been updated for a
  configurable idle period and has not yet been converted to an order.

  Recovery emails are sent via an Oban job queue so that delivery is
  resilient to transient failures. Each cart receives at most one
  recovery sequence per session to prevent over-mailing.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias MyApp.Ecommerce.Cart
  alias MyApp.Workers.RecoveryEmailWorker

  @idle_hours 1
  @max_recovery_emails_per_session 3
  @recovery_delays_hours [1, 24, 72]

  @type recovery_summary :: %{
          carts_identified: non_neg_integer(),
          sequences_scheduled: non_neg_integer(),
          already_sequenced: non_neg_integer()
        }

  @doc """
  Scans for abandoned carts and schedules recovery sequences for those
  that have not yet received one. Returns a summary of the run.
  """
  @spec run() :: recovery_summary()
  def run do
    abandoned = fetch_abandoned_carts()
    {to_schedule, already_done} = Enum.split_with(abandoned, &needs_recovery?/1)

    Enum.each(to_schedule, &schedule_recovery_sequence/1)

    %{
      carts_identified: length(abandoned),
      sequences_scheduled: length(to_schedule),
      already_sequenced: length(already_done)
    }
  end

  @doc """
  Returns the number of recovery emails already sent for `cart_id` in
  the current session.
  """
  @spec emails_sent(String.t()) :: non_neg_integer()
  def emails_sent(cart_id) when is_binary(cart_id) do
    Oban.Job
    |> where([j], j.worker == ^to_string(RecoveryEmailWorker))
    |> where([j], fragment("?->>'cart_id' = ?", j.args, ^cart_id))
    |> select([j], count(j.id))
    |> Repo.one()
    |> Kernel.||(0)
  end

  @spec fetch_abandoned_carts() :: [Cart.t()]
  defp fetch_abandoned_carts do
    cutoff = DateTime.add(DateTime.utc_now(), -@idle_hours, :hour)

    Cart
    |> where([c], is_nil(c.converted_at))
    |> where([c], c.updated_at < ^cutoff)
    |> where([c], not is_nil(c.customer_email))
    |> where([c], c.item_count > 0)
    |> Repo.all()
  end

  @spec needs_recovery?(Cart.t()) :: boolean()
  defp needs_recovery?(cart) do
    emails_sent(cart.id) < @max_recovery_emails_per_session
  end

  @spec schedule_recovery_sequence(Cart.t()) :: :ok
  defp schedule_recovery_sequence(cart) do
    Enum.each(Enum.with_index(@recovery_delays_hours), fn {delay_hours, index} ->
      scheduled_at = DateTime.add(DateTime.utc_now(), delay_hours, :hour)

      %{cart_id: cart.id, email: cart.customer_email, sequence_position: index + 1}
      |> RecoveryEmailWorker.new(scheduled_at: scheduled_at)
      |> Oban.insert()
    end)
  end
end
```
