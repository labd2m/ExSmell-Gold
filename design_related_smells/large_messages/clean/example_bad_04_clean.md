```elixir
defmodule Notifications.Subscriber do
  @enforce_keys [:id, :email, :preferences]
  defstruct [
    :id,
    :email,
    :phone,
    :name,
    :locale,
    :timezone,
    :preferences,
    :tags,
    :device_tokens,
    :segment_ids
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          email: String.t(),
          phone: String.t() | nil,
          name: String.t(),
          locale: String.t(),
          timezone: String.t(),
          preferences: map(),
          tags: list(String.t()),
          device_tokens: list(String.t()),
          segment_ids: list(String.t())
        }
end

defmodule Notifications.Campaign do
  @enforce_keys [:id, :title, :body, :channel]
  defstruct [:id, :title, :body, :channel, :scheduled_at, :template_vars, :metadata]
end

defmodule Notifications.SubscriberRepo do
  @moduledoc "Simulates subscriber retrieval from a data store."

  @spec list_by_segment(String.t()) :: list(Notifications.Subscriber.t())
  def list_by_segment(segment_id) do
    Enum.map(1..30_000, fn i ->
      %Notifications.Subscriber{
        id: "SUB-#{i}",
        email: "user#{i}@example.com",
        phone: "+5511#{String.pad_leading("#{i}", 8, "0")}",
        name: "User #{i}",
        locale: "pt-BR",
        timezone: "America/Sao_Paulo",
        preferences: %{
          email: true,
          sms: rem(i, 3) == 0,
          push: rem(i, 2) == 0,
          marketing: rem(i, 5) != 0
        },
        tags: ["segment:#{segment_id}", "tier:#{Enum.random(["free", "pro", "enterprise"])}"],
        device_tokens: ["tok_#{i}_ios", "tok_#{i}_android"],
        segment_ids: [segment_id, "all_users"]
      }
    end)
  end
end

defmodule Notifications.Broadcaster do
  @moduledoc "Process responsible for sending notifications for a campaign."
  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{sent: 0, failed: 0}, opts)
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_info({:run_campaign, campaign, subscribers}, state) do
    results =
      Enum.reduce(subscribers, {0, 0}, fn sub, {sent, failed} ->
        case deliver(campaign, sub) do
          :ok -> {sent + 1, failed}
          :error -> {sent, failed + 1}
        end
      end)

    {sent, failed} = results
    {:noreply, %{state | sent: state.sent + sent, failed: state.failed + failed}}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    {:reply, state, state}
  end

  defp deliver(_campaign, _subscriber) do
    # Simulates delivery latency
    if :rand.uniform(100) > 2, do: :ok, else: :error
  end
end

defmodule Notifications.CampaignDispatcher do
  @moduledoc "Fetches subscribers and dispatches campaigns to the Broadcaster process."

  require Logger

  @spec broadcast(pid(), Notifications.Campaign.t()) :: :ok
  def broadcast(broadcaster_pid, %Notifications.Campaign{} = campaign) do
    Logger.info("Preparing campaign #{campaign.id} — fetching subscribers")

    subscribers = Notifications.SubscriberRepo.list_by_segment("weekly_digest")

    Logger.info("Dispatching #{length(subscribers)} subscribers to broadcaster")

    send(broadcaster_pid, {:run_campaign, campaign, subscribers})

    :ok
  end

  @spec schedule_all(list(Notifications.Campaign.t())) :: :ok
  def schedule_all(campaigns) do
    {:ok, broadcaster} = Notifications.Broadcaster.start_link()

    Enum.each(campaigns, fn campaign ->
      broadcast(broadcaster, campaign)
    end)
  end
end
```
