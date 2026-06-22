```elixir
defmodule Realtime.Topic do
  @moduledoc """
  Represents a named pub/sub topic with optional access restrictions.
  """

  @type t :: %__MODULE__{
          name: String.t(),
          public: boolean(),
          max_subscribers: pos_integer() | :unlimited
        }

  defstruct [:name, public: true, max_subscribers: :unlimited]
end

defmodule Realtime.PubSub do
  use GenServer

  alias Realtime.Topic

  @moduledoc """
  An in-process publish/subscribe broker supporting named topics.
  Subscribers receive messages directly to their process mailbox.
  Topics enforce optional subscriber limits and access policies.
  """

  @type subscription_id :: reference()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put(opts, :name, __MODULE__))
  end

  @spec declare_topic(Topic.t()) :: :ok | {:error, :already_exists}
  def declare_topic(%Topic{} = topic) do
    GenServer.call(__MODULE__, {:declare, topic})
  end

  @spec subscribe(String.t(), pid()) ::
          {:ok, subscription_id()} | {:error, :topic_not_found | :subscriber_limit_reached}
  def subscribe(topic_name, subscriber_pid \\ self())
      when is_binary(topic_name) and is_pid(subscriber_pid) do
    GenServer.call(__MODULE__, {:subscribe, topic_name, subscriber_pid})
  end

  @spec unsubscribe(subscription_id()) :: :ok
  def unsubscribe(subscription_id) when is_reference(subscription_id) do
    GenServer.cast(__MODULE__, {:unsubscribe, subscription_id})
  end

  @spec publish(String.t(), term()) :: {:ok, non_neg_integer()} | {:error, :topic_not_found}
  def publish(topic_name, message) when is_binary(topic_name) do
    GenServer.call(__MODULE__, {:publish, topic_name, message})
  end

  @impl GenServer
  def init(:ok) do
    {:ok, %{topics: %{}, subscriptions: %{}}}
  end

  @impl GenServer
  def handle_call({:declare, topic}, _from, state) do
    if Map.has_key?(state.topics, topic.name) do
      {:reply, {:error, :already_exists}, state}
    else
      new_state = put_in(state.topics[topic.name], {topic, []})
      {:reply, :ok, new_state}
    end
  end

  def handle_call({:subscribe, topic_name, pid}, _from, state) do
    case Map.fetch(state.topics, topic_name) do
      :error ->
        {:reply, {:error, :topic_not_found}, state}

      {:ok, {topic, subscribers}} ->
        cond do
          topic.max_subscribers != :unlimited and length(subscribers) >= topic.max_subscribers ->
            {:reply, {:error, :subscriber_limit_reached}, state}

          true ->
            sub_id = make_ref()
            ref = Process.monitor(pid)
            new_subscribers = [{sub_id, pid, ref} | subscribers]
            new_state =
              state
              |> put_in([:topics, topic_name], {topic, new_subscribers})
              |> put_in([:subscriptions, sub_id], {topic_name, ref})

            {:reply, {:ok, sub_id}, new_state}
        end
    end
  end

  def handle_call({:publish, topic_name, message}, _from, state) do
    case Map.fetch(state.topics, topic_name) do
      :error ->
        {:reply, {:error, :topic_not_found}, state}

      {:ok, {_topic, subscribers}} ->
        Enum.each(subscribers, fn {_, pid, _} -> send(pid, {:pubsub, topic_name, message}) end)
        {:reply, {:ok, length(subscribers)}, state}
    end
  end

  @impl GenServer
  def handle_cast({:unsubscribe, sub_id}, state) do
    case Map.fetch(state.subscriptions, sub_id) do
      :error -> {:noreply, state}
      {:ok, {topic_name, monitor_ref}} ->
        Process.demonitor(monitor_ref, [:flush])
        new_state = remove_subscription(state, sub_id, topic_name)
        {:noreply, new_state}
    end
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    sub_id = find_by_monitor(state.subscriptions, ref)

    case sub_id do
      nil -> {:noreply, state}
      id ->
        {topic_name, _} = state.subscriptions[id]
        {:noreply, remove_subscription(state, id, topic_name)}
    end
  end

  defp remove_subscription(state, sub_id, topic_name) do
    state
    |> Map.update!(:subscriptions, &Map.delete(&1, sub_id))
    |> Map.update!(:topics, fn topics ->
      Map.update!(topics, topic_name, fn {topic, subs} ->
        {topic, Enum.reject(subs, fn {id, _, _} -> id == sub_id end)}
      end)
    end)
  end

  defp find_by_monitor(subscriptions, ref) do
    Enum.find_value(subscriptions, fn {id, {_, mon_ref}} ->
      if mon_ref == ref, do: id
    end)
  end
end
```
