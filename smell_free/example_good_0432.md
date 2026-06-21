```elixir
defmodule MyAppWeb.Live.DocumentUpload do
  @moduledoc """
  A LiveView that handles direct-to-S3 multipart file uploads using
  Phoenix LiveView's upload API. Files are streamed in chunks to avoid
  loading the entire payload into memory on the server. Upload entries are
  validated for content type and size before the presigned URL is issued.
  Completed uploads are registered in the media library via a context call.
  """

  use MyAppWeb, :live_view

  alias MyApp.MediaLibrary

  require Logger

  @allowed_types ~w[application/pdf image/jpeg image/png image/webp]
  @max_file_size_mb 25
  @max_file_size_bytes @max_file_size_mb * 1024 * 1024

  @impl Phoenix.LiveView
  def mount(_params, session, socket) do
    socket =
      socket
      |> assign(current_user: load_user(session))
      |> assign(uploads_complete: [])
      |> assign(error_messages: [])
      |> allow_upload(:documents,
        accept: @allowed_types,
        max_entries: 5,
        max_file_size: @max_file_size_bytes,
        external: &presign_upload/2
      )

    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("validate", _params, socket) do
    {:noreply, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("upload", _params, socket) do
    {completed, errors} =
      consume_uploaded_entries(socket, :documents, fn %{key: key}, entry ->
        case MediaLibrary.register_upload(socket.assigns.current_user.id, entry, key) do
          {:ok, media} -> {:ok, media}
          {:error, reason} -> {:error, reason}
        end
      end)

    error_messages =
      Enum.map(errors, fn
        {:error, reason} -> format_upload_error(reason)
        _ -> "An unknown error occurred"
      end)

    socket =
      socket
      |> update(:uploads_complete, &(&1 ++ completed))
      |> assign(:error_messages, error_messages)

    {:noreply, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :documents, ref)}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="upload-container">
      <form id="upload-form" phx-submit="upload" phx-change="validate">
        <.live_file_input upload={@uploads.documents} />
        <button type="submit">Upload Documents</button>
      </form>

      <%= for entry <- @uploads.documents.entries do %>
        <div class="upload-entry">
          <span><%= entry.client_name %></span>
          <progress value={entry.progress} max="100" />
          <button type="button" phx-click="cancel_upload" phx-value-ref={entry.ref}>
            Cancel
          </button>
          <%= for err <- upload_errors(@uploads.documents, entry) do %>
            <p class="error"><%= format_upload_error(err) %></p>
          <% end %>
        </div>
      <% end %>

      <%= for message <- @error_messages do %>
        <p class="error"><%= message %></p>
      <% end %>

      <%= for media <- @uploads_complete do %>
        <p class="success">Uploaded: <%= media.filename %></p>
      <% end %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp presign_upload(entry, socket) do
    user_id = socket.assigns.current_user.id
    key = "uploads/#{user_id}/#{entry.uuid}/#{entry.client_name}"
    content_type = entry.client_type

    case MyApp.Storage.presigned_put(key, content_type, @max_file_size_bytes) do
      {:ok, %{url: url, fields: fields}} ->
        meta = %{uploader: "S3", key: key, url: url, fields: fields}
        {:ok, meta, socket}

      {:error, reason} ->
        Logger.error("Failed to generate presigned URL", reason: inspect(reason))
        {:error, :presign_failed}
    end
  end

  defp load_user(%{"user_id" => user_id}) do
    MyApp.Accounts.get_user!(user_id)
  end

  defp format_upload_error(:too_large), do: "File exceeds the #{@max_file_size_mb}MB limit"
  defp format_upload_error(:not_accepted), do: "File type not supported"
  defp format_upload_error(:too_many_files), do: "Maximum 5 files per upload"
  defp format_upload_error(:presign_failed), do: "Could not initiate upload, please try again"
  defp format_upload_error(other), do: "Upload error: #{inspect(other)}"
end
```
