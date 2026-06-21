```elixir
defmodule Comms.InboxContext do
  @moduledoc """
  Manages in-app messaging inboxes. Conversations are two-party threads.
  Messages are append-only and soft-deleted, preserving conversation
  history for compliance. Unread counts are maintained via a separate
  denormalised counter table to avoid counting scans on hot paths.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias Comms.{Conversation, Message, UnreadCount}

  @type user_id :: String.t()
  @type conversation_id :: Ecto.UUID.t()
  @type message_id :: Ecto.UUID.t()

  @doc "Creates or fetches the conversation thread between two users."
  @spec get_or_create_conversation(user_id(), user_id()) ::
          {:ok, Conversation.t()} | {:error, Ecto.Changeset.t()}
  def get_or_create_conversation(user_a, user_b) when user_a != user_b do
    [p1, p2] = Enum.sort([user_a, user_b])

    case Repo.get_by(Conversation, participant_1: p1, participant_2: p2) do
      %Conversation{} = conv -> {:ok, conv}
      nil ->
        %Conversation{}
        |> Conversation.changeset(%{participant_1: p1, participant_2: p2})
        |> Repo.insert()
    end
  end

  @doc "Sends a message in `conversation_id` from `sender_id`."
  @spec send_message(conversation_id(), user_id(), String.t()) ::
          {:ok, Message.t()} | {:error, :forbidden | Ecto.Changeset.t()}
  def send_message(conversation_id, sender_id, body)
      when is_binary(conversation_id) and is_binary(sender_id) and is_binary(body) do
    case Repo.get(Conversation, conversation_id) do
      nil ->
        {:error, :forbidden}

      %Conversation{} = conv ->
        if participant?(conv, sender_id) do
          Repo.transaction(fn ->
            recipient_id = other_participant(conv, sender_id)
            with {:ok, msg} <- insert_message(conversation_id, sender_id, body) do
              increment_unread(conversation_id, recipient_id)
              msg
            end
          end)
        else
          {:error, :forbidden}
        end
    end
  end

  @doc "Marks all messages in a conversation as read for `user_id`."
  @spec mark_read(conversation_id(), user_id()) :: :ok
  def mark_read(conversation_id, user_id) when is_binary(conversation_id) do
    Repo.delete_all(
      from(u in UnreadCount,
        where: u.conversation_id == ^conversation_id and u.user_id == ^user_id
      )
    )
    :ok
  end

  @doc "Returns paginated messages for a conversation, newest first."
  @spec messages(conversation_id(), pos_integer(), pos_integer()) :: [Message.t()]
  def messages(conversation_id, page \ 1, per_page \ 30)
      when is_binary(conversation_id) and is_integer(page) and is_integer(per_page) do
    Message
    |> where([m], m.conversation_id == ^conversation_id and is_nil(m.deleted_at))
    |> order_by([m], desc: m.inserted_at)
    |> limit(^per_page)
    |> offset(^((page - 1) * per_page))
    |> Repo.all()
  end

  @doc "Returns the total unread count across all conversations for `user_id`."
  @spec total_unread(user_id()) :: non_neg_integer()
  def total_unread(user_id) when is_binary(user_id) do
    from(u in UnreadCount,
      where: u.user_id == ^user_id,
      select: sum(u.count)
    )
    |> Repo.one()
    |> Kernel.||(0)
  end

  defp participant?(%Conversation{participant_1: p1, participant_2: p2}, user_id) do
    user_id in [p1, p2]
  end

  defp other_participant(%Conversation{participant_1: p1, participant_2: p2}, user_id) do
    if user_id == p1, do: p2, else: p1
  end

  defp insert_message(conversation_id, sender_id, body) do
    %Message{}
    |> Message.changeset(%{conversation_id: conversation_id, sender_id: sender_id, body: body})
    |> Repo.insert()
  end

  defp increment_unread(conversation_id, user_id) do
    Repo.insert_all(
      UnreadCount,
      [%{conversation_id: conversation_id, user_id: user_id, count: 1}],
      on_conflict: [inc: [count: 1]],
      conflict_target: [:conversation_id, :user_id]
    )
  end
end
```
