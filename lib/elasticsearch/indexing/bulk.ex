defmodule Elasticsearch.Index.Bulk do
  @moduledoc """
  Functions for creating bulk indexing requests.
  """

  alias Elasticsearch.{
    Cluster,
    Document
  }

  require Logger

  @doc """
  Encodes a given variable into an Elasticsearch bulk request. The variable
  must implement `Elasticsearch.Document`.

  ## Examples

      iex> Bulk.encode(Cluster, %Post{id: "my-id"}, "my-index")
      {:ok, \"\"\"
      {"index":{"_index":"my-index","_id":"my-id"}}
      {"title":null,"doctype":{"name":"post"},"author":null}
      \"\"\"}

      iex> Bulk.encode(Cluster, 123, "my-index")
      {:error,
        %Protocol.UndefinedError{description: "",
        protocol: Elasticsearch.Document, value: 123}}
  """
  @spec encode(Cluster.t(), struct, String.t()) ::
          {:ok, String.t()}
          | {:error, Error.t()}
  def encode(cluster, struct, index) do
    {:ok, encode!(cluster, struct, index)}
  rescue
    exception ->
      {:error, exception}
  end

  @doc """
  Same as `encode/3`, but returns the request and raises errors.

  ## Example

      iex> Bulk.encode!(Cluster, %Post{id: "my-id"}, "my-index")
      \"\"\"
      {"index":{"_index":"my-index","_id":"my-id"}}
      {"title":null,"doctype":{"name":"post"},"author":null}
      \"\"\"

      iex> Bulk.encode!(Cluster, 123, "my-index")
      ** (Protocol.UndefinedError) protocol Elasticsearch.Document not implemented for 123 of type Integer. This protocol is implemented for the following type(s): Comment, Post
  """
  def encode!(cluster, struct, index) do
    config = Cluster.Config.get(cluster)
    header = header(config, "index", index, struct)

    document =
      struct
      |> Document.encode()
      |> config.json_library.encode!()

    "#{header}\n#{document}\n"
  end

  defp header(config, type, index, struct) do
    attrs = %{
      "_index" => index,
      "_id" => Document.id(struct)
    }

    attrs =
      if routing = Document.routing(struct) do
        Map.put(attrs, "_routing", routing)
      else
        attrs
      end

    config.json_library.encode!(%{type => attrs})
  end

  @doc """
  Uploads all the data from the list of `sources` to the given index.
  Data for each `source` will be fetched using the configured `:store`.
  """
  @spec upload(Cluster.t(), index_name :: String.t(), Elasticsearch.Store.t(), list) ::
          :ok | {:error, [map]}
  def upload(cluster, index_name, index_config, errors \\ [])
  def upload(_cluster, _index_name, %{sources: []}, []), do: :ok
  def upload(_cluster, _index_name, %{sources: []}, errors), do: {:error, errors}

  def upload(
        cluster,
        index_name,
        %{store: store, sources: [source | tail]} = index_config,
        errors
      )
      when is_atom(store) do
    config = Cluster.Config.get(cluster)
    bulk_page_size = index_config[:bulk_page_size] || 5000
    bulk_wait_interval = index_config[:bulk_wait_interval] || 0

    errors =
      store.transaction(fn ->
        source
        |> store.stream()
        |> Stream.map(&encode!(config, &1, index_name))
        |> Stream.chunk_every(bulk_page_size)
        |> Stream.intersperse(bulk_wait_interval)
        |> Stream.map(&put_bulk_page(config, index_name, &1))
        |> Enum.reduce(errors, &collect_errors/2)
      end)

    upload(config, index_name, %{index_config | sources: tail}, errors)
  end

  defp put_bulk_page(_config, _index_name, wait_interval) when is_integer(wait_interval) do
    Logger.debug("Pausing #{wait_interval}ms between bulk pages")
    :timer.sleep(wait_interval)
  end

  defp put_bulk_page(config, index_name, items) when is_list(items) do
    Elasticsearch.put(config, "/#{index_name}/_bulk", Enum.join(items))
  end

  defp collect_errors({:ok, %{"errors" => true} = response}, errors) do
    new_errors =
      response["items"]
      |> Enum.filter(&(&1["index"]["error"] != nil))
      |> Enum.map(& &1["index"])
      |> Enum.map(&Elasticsearch.Exception.exception(response: &1))

    new_errors ++ errors
  end

  defp collect_errors({:error, error}, errors) do
    [error | errors]
  end

  defp collect_errors(_response, errors) do
    errors
  end
end
