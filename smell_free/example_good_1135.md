```elixir
defmodule Apiclient.Github do
  @moduledoc """
  Typed client for the GitHub REST API v3.
  All functions return structured result tuples. Configuration is
  accepted per-call via options, enabling concurrent use with
  different tokens in the same runtime.
  """

  alias Apiclient.Github.{Repository, PullRequest, HttpAdapter}

  @base_url "https://api.github.com"

  @type client_opts :: [
          token: String.t(),
          timeout_ms: pos_integer(),
          user_agent: String.t()
        ]

  @type api_error :: {:error, :unauthorized | :not_found | :rate_limited | :server_error | String.t()}

  @spec get_repository(String.t(), String.t(), client_opts()) ::
          {:ok, Repository.t()} | api_error()
  def get_repository(owner, repo, opts \\ [])
      when is_binary(owner) and is_binary(repo) do
    path = "/repos/#{owner}/#{repo}"

    with {:ok, body} <- get(path, opts) do
      {:ok, Repository.from_map(body)}
    end
  end

  @spec list_pull_requests(String.t(), String.t(), keyword(), client_opts()) ::
          {:ok, [PullRequest.t()]} | api_error()
  def list_pull_requests(owner, repo, filters \\ [], opts \\ [])
      when is_binary(owner) and is_binary(repo) do
    state = Keyword.get(filters, :state, "open")
    per_page = Keyword.get(filters, :per_page, 30)
    path = "/repos/#{owner}/#{repo}/pulls?state=#{state}&per_page=#{per_page}"

    with {:ok, body} <- get(path, opts) do
      {:ok, Enum.map(body, &PullRequest.from_map/1)}
    end
  end

  @spec get_pull_request(String.t(), String.t(), pos_integer(), client_opts()) ::
          {:ok, PullRequest.t()} | api_error()
  def get_pull_request(owner, repo, number, opts \\ [])
      when is_binary(owner) and is_binary(repo) and is_integer(number) and number > 0 do
    path = "/repos/#{owner}/#{repo}/pulls/#{number}"

    with {:ok, body} <- get(path, opts) do
      {:ok, PullRequest.from_map(body)}
    end
  end

  @spec get(String.t(), client_opts()) :: {:ok, map() | list()} | api_error()
  defp get(path, opts) do
    url = @base_url <> path
    headers = build_headers(opts)
    timeout = Keyword.get(opts, :timeout_ms, 10_000)

    url
    |> HttpAdapter.get(headers, timeout)
    |> parse_response()
  end

  @spec build_headers(client_opts()) :: [{String.t(), String.t()}]
  defp build_headers(opts) do
    token = Keyword.get(opts, :token)
    user_agent = Keyword.get(opts, :user_agent, "apiclient-github/1.0")

    base = [
      {"accept", "application/vnd.github+json"},
      {"x-github-api-version", "2022-11-28"},
      {"user-agent", user_agent}
    ]

    if is_binary(token) do
      [{"authorization", "Bearer #{token}"} | base]
    else
      base
    end
  end

  @spec parse_response({:ok, non_neg_integer(), map() | list()} | {:error, term()}) ::
          {:ok, map() | list()} | api_error()
  defp parse_response({:ok, 200, body}), do: {:ok, body}
  defp parse_response({:ok, 201, body}), do: {:ok, body}
  defp parse_response({:ok, 401, _body}), do: {:error, :unauthorized}
  defp parse_response({:ok, 404, _body}), do: {:error, :not_found}
  defp parse_response({:ok, 429, _body}), do: {:error, :rate_limited}
  defp parse_response({:ok, status, _body}) when status >= 500, do: {:error, :server_error}
  defp parse_response({:ok, status, _body}), do: {:error, "unexpected status: #{status}"}
  defp parse_response({:error, reason}), do: {:error, inspect(reason)}
end

defmodule Apiclient.Github.Repository do
  @moduledoc "Typed struct representing a GitHub repository resource."

  @type t :: %__MODULE__{
          id: integer(),
          full_name: String.t(),
          description: String.t() | nil,
          private: boolean(),
          default_branch: String.t(),
          star_count: non_neg_integer(),
          fork_count: non_neg_integer(),
          open_issues_count: non_neg_integer()
        }

  defstruct [:id, :full_name, :description, :private, :default_branch,
             :star_count, :fork_count, :open_issues_count]

  @spec from_map(map()) :: t()
  def from_map(body) when is_map(body) do
    %__MODULE__{
      id: body["id"],
      full_name: body["full_name"],
      description: body["description"],
      private: body["private"],
      default_branch: body["default_branch"],
      star_count: body["stargazers_count"] || 0,
      fork_count: body["forks_count"] || 0,
      open_issues_count: body["open_issues_count"] || 0
    }
  end
end

defmodule Apiclient.Github.PullRequest do
  @moduledoc "Typed struct representing a GitHub pull request resource."

  @type state :: :open | :closed

  @type t :: %__MODULE__{
          id: integer(),
          number: pos_integer(),
          title: String.t(),
          state: state(),
          draft: boolean(),
          author_login: String.t(),
          head_ref: String.t(),
          base_ref: String.t()
        }

  defstruct [:id, :number, :title, :state, :draft, :author_login, :head_ref, :base_ref]

  @spec from_map(map()) :: t()
  def from_map(body) when is_map(body) do
    %__MODULE__{
      id: body["id"],
      number: body["number"],
      title: body["title"],
      state: parse_state(body["state"]),
      draft: body["draft"] || false,
      author_login: get_in(body, ["user", "login"]),
      head_ref: get_in(body, ["head", "ref"]),
      base_ref: get_in(body, ["base", "ref"])
    }
  end

  defp parse_state("open"), do: :open
  defp parse_state("closed"), do: :closed
  defp parse_state(_), do: :open
end
```
