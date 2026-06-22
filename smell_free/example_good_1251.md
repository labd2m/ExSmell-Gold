```elixir
defmodule Compliance.Gdpr.DataSubjectRequests do
  @moduledoc """
  Handles GDPR data subject requests including access, erasure, and portability.
  Each request type is validated, recorded, and dispatched to the appropriate
  handler module. All operations return explicit result tuples.
  """

  alias Compliance.Gdpr.{Request, RequestLog, HandlerRegistry}

  @type request_type :: :access | :erasure | :portability | :rectification
  @type submit_result :: {:ok, Request.t()} | {:error, atom() | String.t()}

  @doc """
  Submits a new data subject request for `subject_id` of the given `type`.

  Validates the request, persists it to the log, and dispatches it for processing.
  Returns `{:ok, request}` on success.
  """
  @spec submit(String.t(), request_type(), map(), keyword()) :: submit_result()
  def submit(subject_id, type, metadata \\ %{}, opts \\ [])
      when is_binary(subject_id) and is_atom(type) and is_map(metadata) do
    log = Keyword.get(opts, :log, RequestLog)
    registry = Keyword.get(opts, :registry, HandlerRegistry)

    with :ok <- validate_type(type),
         :ok <- validate_subject_id(subject_id),
         :ok <- check_no_pending(subject_id, type, log),
         {:ok, request} <- build_request(subject_id, type, metadata),
         {:ok, saved} <- log.insert(request),
         :ok <- dispatch(saved, registry) do
      {:ok, saved}
    end
  end

  @doc """
  Marks a pending request as fulfilled.
  Returns `{:error, :not_found}` or `{:error, :already_resolved}` when ineligible.
  """
  @spec resolve(String.t(), map(), keyword()) :: {:ok, Request.t()} | {:error, atom()}
  def resolve(request_id, resolution_metadata \\ %{}, opts \\ [])
      when is_binary(request_id) and is_map(resolution_metadata) do
    log = Keyword.get(opts, :log, RequestLog)

    with {:ok, request} <- log.fetch(request_id),
         :ok <- assert_pending(request),
         {:ok, resolved} <- log.resolve(request.id, resolution_metadata, DateTime.utc_now()) do
      {:ok, resolved}
    end
  end

  @doc """
  Returns all requests for `subject_id`, optionally filtered by status.
  """
  @spec list_for_subject(String.t(), keyword()) :: {:ok, [Request.t()]}
  def list_for_subject(subject_id, opts \\ []) when is_binary(subject_id) do
    log = Keyword.get(opts, :log, RequestLog)
    status_filter = Keyword.get(opts, :status)
    log.list_by_subject(subject_id, status_filter)
  end

  @supported_types ~w(access erasure portability rectification)a

  defp validate_type(type) when type in @supported_types, do: :ok
  defp validate_type(type), do: {:error, "unsupported request type: #{inspect(type)}"}

  defp validate_subject_id(id) when is_binary(id) and id != "", do: :ok
  defp validate_subject_id(_), do: {:error, "subject_id must be a non-empty string"}

  defp check_no_pending(subject_id, type, log) do
    case log.fetch_pending(subject_id, type) do
      {:error, :not_found} -> :ok
      {:ok, _} -> {:error, :pending_request_exists}
    end
  end

  defp build_request(subject_id, type, metadata) do
    {:ok,
     %Request{
       id: Ecto.UUID.generate(),
       subject_id: subject_id,
       type: type,
       status: :pending,
       metadata: metadata,
       submitted_at: DateTime.utc_now(),
       resolved_at: nil
     }}
  end

  defp assert_pending(%Request{status: :pending}), do: :ok
  defp assert_pending(%Request{}), do: {:error, :already_resolved}

  defp dispatch(request, registry) do
    case registry.handler_for(request.type) do
      {:ok, handler} -> handler.process(request)
      {:error, :no_handler} -> {:error, :no_handler_registered}
    end
  end
end
```
