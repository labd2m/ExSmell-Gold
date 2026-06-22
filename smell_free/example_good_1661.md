```elixir
defmodule Contracts.SigningRequest do
  @moduledoc """
  A pending document signing request sent to one or more signatories.
  """

  @type status :: :draft | :sent | :partially_signed | :completed | :expired | :voided

  @type t :: %__MODULE__{
          id: String.t(),
          document_id: String.t(),
          signatories: [%{email: String.t(), name: String.t(), signed_at: DateTime.t() | nil}],
          status: status(),
          expires_at: DateTime.t(),
          created_by: String.t()
        }

  defstruct [:id, :document_id, :signatories, :expires_at, :created_by, status: :draft]

  @spec all_signed?(t()) :: boolean()
  def all_signed?(%__MODULE__{signatories: signatories}) do
    Enum.all?(signatories, fn s -> not is_nil(s.signed_at) end)
  end

  @spec expired?(t()) :: boolean()
  def expired?(%__MODULE__{expires_at: exp}) do
    DateTime.compare(DateTime.utc_now(), exp) == :gt
  end

  @spec pending_signatories(t()) :: [map()]
  def pending_signatories(%__MODULE__{signatories: signatories}) do
    Enum.filter(signatories, fn s -> is_nil(s.signed_at) end)
  end
end

defmodule Contracts.Workflow do
  alias Contracts.SigningRequest

  @moduledoc """
  Manages state transitions for document signing requests.
  All transitions are explicit and validated against current status.
  """

  @type transition_result :: {:ok, SigningRequest.t()} | {:error, atom()}

  @spec send_for_signature(SigningRequest.t()) :: transition_result()
  def send_for_signature(%SigningRequest{status: :draft} = req) do
    {:ok, %{req | status: :sent}}
  end

  def send_for_signature(%SigningRequest{}), do: {:error, :invalid_transition}

  @spec record_signature(SigningRequest.t(), String.t()) :: transition_result()
  def record_signature(%SigningRequest{status: status} = req, email)
      when status in [:sent, :partially_signed] and is_binary(email) do
    if SigningRequest.expired?(req) do
      {:error, :signing_request_expired}
    else
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      updated_signatories =
        Enum.map(req.signatories, fn s ->
          if s.email == email and is_nil(s.signed_at), do: %{s | signed_at: now}, else: s
        end)

      updated_req = %{req | signatories: updated_signatories}

      new_status =
        if SigningRequest.all_signed?(updated_req), do: :completed, else: :partially_signed

      {:ok, %{updated_req | status: new_status}}
    end
  end

  def record_signature(%SigningRequest{}, _email), do: {:error, :invalid_transition}

  @spec void(SigningRequest.t(), String.t()) :: transition_result()
  def void(%SigningRequest{status: status} = req, reason)
      when status in [:draft, :sent, :partially_signed] and is_binary(reason) do
    {:ok, %{req | status: :voided}}
  end

  def void(%SigningRequest{}, _reason), do: {:error, :invalid_transition}

  @spec mark_expired(SigningRequest.t()) :: transition_result()
  def mark_expired(%SigningRequest{status: status} = req)
      when status in [:sent, :partially_signed] do
    {:ok, %{req | status: :expired}}
  end

  def mark_expired(%SigningRequest{}), do: {:error, :invalid_transition}
end
```
