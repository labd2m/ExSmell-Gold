```elixir
defmodule AppWeb.BoardChannel do
  @moduledoc """
  A Phoenix Channel for real-time collaboration on a shared board.

  Clients join a `board:<id>` topic and receive live updates for cursor
  movements, block edits, and presence changes. Membership is verified on
  join; all incoming events are validated before processing.
  """

  use Phoenix.Channel

  alias AppWeb.Presence
  alias App.Boards

  @impl Phoenix.Channel
  def join("board:" <> board_id, _params, socket) do
    account = socket.assigns.current_account

    case Boards.authorize_member(board_id, account.id) do
      {:ok, board} ->
        socket = assign(socket, :board, board)
        send(self(), :after_join)
        {:ok, %{board_id: board.id, name: board.name}, socket}

      {:error, :not_a_member} ->
        {:error, %{reason: "not_authorized"}}

      {:error, :board_not_found} ->
        {:error, %{reason: "board_not_found"}}
    end
  end

  @impl Phoenix.Channel
  def handle_info(:after_join, socket) do
    {:ok, _} = Presence.track(socket, socket.assigns.current_account.id, presence_meta(socket))
    push(socket, "presence_state", Presence.list(socket))
    {:noreply, socket}
  end

  @impl Phoenix.Channel
  def handle_in("cursor_moved", %{"x" => x, "y" => y}, socket)
      when is_number(x) and is_number(y) do
    broadcast_from!(socket, "cursor_moved", %{
      account_id: socket.assigns.current_account.id,
      x: x,
      y: y
    })

    {:noreply, socket}
  end

  @impl Phoenix.Channel
  def handle_in("block_updated", %{"block_id" => id, "content" => content}, socket)
      when is_binary(id) and is_binary(content) do
    board = socket.assigns.board
    account = socket.assigns.current_account

    case Boards.update_block(board, id, content, account) do
      {:ok, block} ->
        broadcast!(socket, "block_updated", block_payload(block))
        {:reply, {:ok, block_payload(block)}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: Atom.to_string(reason)}}, socket}
    end
  end

  @impl Phoenix.Channel
  def handle_in("block_deleted", %{"block_id" => id}, socket) when is_binary(id) do
    board = socket.assigns.board
    account = socket.assigns.current_account

    case Boards.delete_block(board, id, account) do
      :ok ->
        broadcast!(socket, "block_deleted", %{block_id: id})
        {:reply, :ok, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: Atom.to_string(reason)}}, socket}
    end
  end

  @impl Phoenix.Channel
  def handle_in(_event, _params, socket) do
    {:reply, {:error, %{reason: "unknown_event"}}, socket}
  end

  @impl Phoenix.Channel
  def terminate(_reason, socket) do
    Presence.untrack(socket, socket.assigns.current_account.id)
    :ok
  end

  defp presence_meta(socket) do
    %{
      name: socket.assigns.current_account.name,
      online_at: DateTime.to_iso8601(DateTime.utc_now())
    }
  end

  defp block_payload(block) do
    %{
      block_id: block.id,
      type: block.type,
      content: block.content,
      position: block.position,
      updated_at: DateTime.to_iso8601(block.updated_at)
    }
  end
end
```
