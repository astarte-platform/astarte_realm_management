defmodule Astarte.RealmManagement.Engine do
  require Logger
  alias CQEx.Client, as: DatabaseClient

  def process_rpc(message) do
    case Astarte.RPC.Protocol.RealmManagement.Call.decode(message) do
      %Astarte.RPC.Protocol.RealmManagement.Call{call: call_tuple} when call_tuple != nil ->
        case call_tuple do
          {:install_interface, %Astarte.RPC.Protocol.RealmManagement.InstallInterface{realm_name: realm_name, interface_json: interface_json}} ->
          install_interface(realm_name, interface_json)
        _ ->
          Logger.warn "Received unexpected call: " <> inspect call_tuple
          {:error, :unexpected_call}
        end
      _ ->
        Logger.warn "Received unexpected message: " <> inspect message
        {:error, :unexpected_messsage}
    end
  end

  def install_interface(realm_name, interface_json) do
    interface_document = Astarte.Core.InterfaceDocument.from_json(interface_json)

    DatabaseClient.new!(List.first(Application.get_env(:cqerl, :cassandra_nodes)), [keyspace: realm_name])
    |> Astarte.RealmManagement.Queries.install_new_interface(interface_document)
  end

end