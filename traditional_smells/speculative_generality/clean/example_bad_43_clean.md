```elixir
defmodule UserManagement.UserSearch do
  @moduledoc """
  Provides full-text and attribute-based search over user accounts.

  Search results are paginated and ranked by relevance. Matching is
  performed against display name, email address, and company fields.
  """

  alias UserManagement.{Account, SearchIndex, SearchResult}

  require Logger

  @default_page_size 25
  @max_page_size 100

  @spec search(String.t()) ::
          {:ok, SearchResult.t()} | {:error, atom()}
  
  
  
  
  
  
  
  def search(query, opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    page_size = opts |> Keyword.get(:page_size, @default_page_size) |> min(@max_page_size)
    include_inactive = Keyword.get(opts, :include_inactive, false)

    with :ok <- validate_query(query),
         {:ok, filters} <- build_filters(include_inactive),
         {:ok, hits} <- SearchIndex.query(query, filters, page, page_size),
         {:ok, accounts} <- hydrate_accounts(hits.ids),
         {:ok, ranked} <- rank_results(accounts, query) do
      result = %SearchResult{
        items: ranked,
        total_count: hits.total,
        page: page,
        page_size: page_size,
        query: query
      }

      Logger.debug("Search completed query=#{inspect(query)} hits=#{hits.total}")
      {:ok, result}
    else
      {:error, :query_too_short} ->
        {:error, :query_too_short}

      {:error, reason} ->
        Logger.error("Search failed query=#{inspect(query)}: #{inspect(reason)}")
        {:error, reason}
    end
  end
  

  defp build_filters(include_inactive) do
    base_filters = %{verified: true}

    filters =
      if include_inactive do
        base_filters
      else
        Map.put(base_filters, :status, [:active])
      end

    {:ok, filters}
  end

  defp validate_query(query) when is_binary(query) and byte_size(query) >= 2, do: :ok
  defp validate_query(_), do: {:error, :query_too_short}

  defp hydrate_accounts(ids) do
    accounts =
      ids
      |> Enum.map(&Account.fetch/1)
      |> Enum.flat_map(fn
        {:ok, acc} -> [acc]
        _ -> []
      end)

    {:ok, accounts}
  end

  defp rank_results(accounts, query) do
    q = String.downcase(query)

    ranked =
      accounts
      |> Enum.map(fn acc ->
        score = relevance_score(acc, q)
        {acc, score}
      end)
      |> Enum.sort_by(fn {_acc, score} -> score end, :desc)
      |> Enum.map(fn {acc, _score} -> acc end)

    {:ok, ranked}
  end

  defp relevance_score(account, query) do
    fields = [
      {account.email, 3},
      {account.display_name, 2},
      {account.company || "", 1}
    ]

    Enum.reduce(fields, 0, fn {field, weight}, acc ->
      if String.contains?(String.downcase(field), query), do: acc + weight, else: acc
    end)
  end
end

defmodule UserManagement.AdminController do
  alias UserManagement.UserSearch

  def search_users(conn) do
    query = Map.get(conn.query_params, "q", "")

    case UserSearch.search(query) do
      {:ok, result} ->
        send_resp(conn, 200, Jason.encode!(%{
          users: Enum.map(result.items, &format_user/1),
          total: result.total_count,
          page: result.page
        }))

      {:error, :query_too_short} ->
        send_resp(conn, 422, Jason.encode!(%{error: "query_too_short"}))

      {:error, _reason} ->
        send_resp(conn, 500, Jason.encode!(%{error: "search_failed"}))
    end
  end

  defp format_user(account) do
    %{id: account.id, email: account.email, display_name: account.display_name}
  end

  defp send_resp(conn, status, body), do: %{conn | status: status, resp_body: body}
end
```
