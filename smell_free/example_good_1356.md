**File:** `example_good_1356.md`

```elixir
defprotocol API.Serializable do
  @moduledoc """
  Defines the contract for converting domain structs into
  API-ready maps suitable for JSON encoding.
  """

  @doc "Converts a domain struct to a plain map for API output."
  @spec to_response(t()) :: map()
  def to_response(entity)
end

defmodule API.User do
  @moduledoc "Domain struct representing an authenticated user."

  @enforce_keys [:id, :email, :role, :inserted_at]
  defstruct [:id, :email, :display_name, :role, :inserted_at]

  @type role :: :admin | :member | :viewer

  @type t :: %__MODULE__{
          id: pos_integer(),
          email: String.t(),
          display_name: String.t() | nil,
          role: role(),
          inserted_at: DateTime.t()
        }
end

defmodule API.Project do
  @moduledoc "Domain struct representing a workspace project."

  @enforce_keys [:id, :name, :owner_id, :visibility, :inserted_at]
  defstruct [:id, :name, :description, :owner_id, :visibility, :inserted_at]

  @type visibility :: :public | :private

  @type t :: %__MODULE__{
          id: pos_integer(),
          name: String.t(),
          description: String.t() | nil,
          owner_id: pos_integer(),
          visibility: visibility(),
          inserted_at: DateTime.t()
        }
end

defmodule API.Invitation do
  @moduledoc "Domain struct representing a pending project invitation."

  @enforce_keys [:id, :project_id, :invitee_email, :expires_at]
  defstruct [:id, :project_id, :invitee_email, :status, :expires_at]

  @type status :: :pending | :accepted | :declined | :expired

  @type t :: %__MODULE__{
          id: pos_integer(),
          project_id: pos_integer(),
          invitee_email: String.t(),
          status: status(),
          expires_at: DateTime.t()
        }
end

defimpl API.Serializable, for: API.User do
  def to_response(%API.User{} = user) do
    %{
      id: user.id,
      email: user.email,
      display_name: user.display_name,
      role: user.role,
      created_at: DateTime.to_iso8601(user.inserted_at)
    }
  end
end

defimpl API.Serializable, for: API.Project do
  def to_response(%API.Project{} = project) do
    %{
      id: project.id,
      name: project.name,
      description: project.description,
      owner_id: project.owner_id,
      visibility: project.visibility,
      created_at: DateTime.to_iso8601(project.inserted_at)
    }
  end
end

defimpl API.Serializable, for: API.Invitation do
  def to_response(%API.Invitation{} = invitation) do
    %{
      id: invitation.id,
      project_id: invitation.project_id,
      invitee_email: invitation.invitee_email,
      status: invitation.status || :pending,
      expires_at: DateTime.to_iso8601(invitation.expires_at)
    }
  end
end

defmodule API.ResponseBuilder do
  @moduledoc """
  Builds standardized envelope responses for single resources and collections.
  """

  alias API.Serializable

  @type envelope :: %{data: map() | [map()]}
  @type paginated_envelope :: %{data: [map()], meta: map()}

  @spec build(Serializable.t()) :: envelope()
  def build(entity) do
    %{data: Serializable.to_response(entity)}
  end

  @spec build_collection([Serializable.t()]) :: envelope()
  def build_collection(entities) do
    %{data: Enum.map(entities, &Serializable.to_response/1)}
  end

  @spec build_paginated([Serializable.t()], pos_integer(), pos_integer(), pos_integer()) ::
          paginated_envelope()
  def build_paginated(entities, page, page_size, total_count) do
    %{
      data: Enum.map(entities, &Serializable.to_response/1),
      meta: %{
        page: page,
        page_size: page_size,
        total_count: total_count,
        total_pages: ceil(total_count / page_size)
      }
    }
  end
end
```
