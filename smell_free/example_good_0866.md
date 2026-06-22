```elixir
defmodule AppWeb.SignalingChannel do
  @moduledoc """
  A Phoenix Channel for WebRTC peer-to-peer session negotiation.

  Peers join a named room topic and exchange SDP offers, SDP answers, and
  ICE candidates through the server. The server relays messages between peers
  without inspecting their content, acting as a transparent signaling relay.
  """

  use Phoenix.Channel

  alias AppWeb.Presence

  @impl Phoenix.Channel
  def join("room:" <> room_id, %{"peer_id" => peer_id}, socket)
      when is_binary(peer_id) and byte_size(peer_id) > 0 do
    socket =
      socket
      |> assign(:room_id, room_id)
      |> assign(:peer_id, peer_id)

    send(self(), :after_join)
    {:ok, %{peer_id: peer_id, room_id: room_id}, socket}
  end

  def join(_topic, _params, _socket) do
    {:error, %{reason: "peer_id required"}}
  end

  @impl Phoenix.Channel
  def handle_info(:after_join, socket) do
    {:ok, _} =
      Presence.track(socket, socket.assigns.peer_id, %{
        peer_id: socket.assigns.peer_id,
        online_at: DateTime.to_iso8601(DateTime.utc_now())
      })

    push(socket, "presence_state", Presence.list(socket))
    {:noreply, socket}
  end

  @doc """
  Handles an SDP offer from the initiating peer. Relays to all other peers
  in the room except the sender.
  """
  @impl Phoenix.Channel
  def handle_in("offer", %{"sdp" => sdp, "target_peer_id" => target}, socket)
      when is_binary(sdp) and is_binary(target) do
    payload = %{sdp: sdp, from_peer_id: socket.assigns.peer_id}
    broadcast_to_peer(socket, target, "offer", payload)
    {:noreply, socket}
  end

  @doc "Relays an SDP answer back to the offering peer."
  @impl Phoenix.Channel
  def handle_in("answer", %{"sdp" => sdp, "target_peer_id" => target}, socket)
      when is_binary(sdp) and is_binary(target) do
    payload = %{sdp: sdp, from_peer_id: socket.assigns.peer_id}
    broadcast_to_peer(socket, target, "answer", payload)
    {:noreply, socket}
  end

  @doc "Relays an ICE candidate to the target peer."
  @impl Phoenix.Channel
  def handle_in("ice_candidate", %{"candidate" => candidate, "target_peer_id" => target}, socket)
      when is_map(candidate) and is_binary(target) do
    payload = %{candidate: candidate, from_peer_id: socket.assigns.peer_id}
    broadcast_to_peer(socket, target, "ice_candidate", payload)
    {:noreply, socket}
  end

  @doc "Notifies other peers that this peer has left."
  @impl Phoenix.Channel
  def handle_in("leave", _params, socket) do
    broadcast_from!(socket, "peer_left", %{peer_id: socket.assigns.peer_id})
    {:stop, :normal, socket}
  end

  @impl Phoenix.Channel
  def handle_in(_event, _params, socket) do
    {:reply, {:error, %{reason: "unknown_event"}}, socket}
  end

  @impl Phoenix.Channel
  def terminate(_reason, socket) do
    broadcast_from!(socket, "peer_left", %{peer_id: socket.assigns.peer_id})
    :ok
  end

  defp broadcast_to_peer(socket, target_peer_id, event, payload) do
    case find_peer_socket(socket.assigns.room_id, target_peer_id) do
      {:ok, _pid} ->
        Phoenix.PubSub.broadcast(
          AppWeb.PubSub,
          "signaling:#{socket.assigns.room_id}:#{target_peer_id}",
          {event, payload}
        )

      :not_found ->
        push(socket, "peer_not_found", %{peer_id: target_peer_id})
    end
  end

  defp find_peer_socket(room_id, peer_id) do
    topic = "room:#{room_id}"
    presences = Presence.list(topic)

    case Map.get(presences, peer_id) do
      nil -> :not_found
      _presence -> {:ok, :found}
    end
  end
end
```
