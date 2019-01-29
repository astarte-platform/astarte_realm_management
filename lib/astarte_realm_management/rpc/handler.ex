#
# This file is part of Astarte.
#
# Copyright 2017-2018 Ispirata Srl
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

defmodule Astarte.RealmManagement.RPC.Handler do
  @behaviour Astarte.RPC.Handler

  alias Astarte.RPC.Protocol.RealmManagement.{
    Call,
    DeleteInterface,
    DeleteTrigger,
    GenericErrorReply,
    GenericOkReply,
    GetHealth,
    GetHealthReply,
    GetInterfacesList,
    GetInterfacesListReply,
    GetInterfaceSource,
    GetInterfaceSourceReply,
    GetInterfaceVersionsList,
    GetInterfaceVersionsListReply,
    GetInterfaceVersionsListReplyVersionTuple,
    GetJWTPublicKeyPEM,
    GetJWTPublicKeyPEMReply,
    GetTrigger,
    GetTriggerReply,
    GetTriggersList,
    GetTriggersListReply,
    InstallInterface,
    InstallTrigger,
    Reply,
    UpdateInterface,
    UpdateJWTPublicKeyPEM
  }

  alias Astarte.Core.Triggers.Trigger
  alias Astarte.RealmManagement.Engine

  require Logger

  def get_health(:get_health, {:ok, %{status: status}}) do
    protobuf_status =
      case status do
        :ready -> :READY
        :degraded -> :DEGRADED
        :bad -> :BAD
        :error -> :ERROR
      end

    msg = %GetHealthReply{
      status: protobuf_status
    }

    {:ok, Reply.encode(%Reply{error: false, reply: {:get_health_reply, msg}})}
  end

  def encode_reply(:get_interface_source, {:ok, reply}) do
    msg = %GetInterfaceSourceReply{
      source: reply
    }

    {:ok, Reply.encode(%Reply{error: false, reply: {:get_interface_source_reply, msg}})}
  end

  def encode_reply(:get_interface_versions_list, {:ok, reply}) do
    msg = %GetInterfaceVersionsListReply{
      versions:
        for version <- reply do
          %GetInterfaceVersionsListReplyVersionTuple{
            major_version: version[:major_version],
            minor_version: version[:minor_version]
          }
        end
    }

    {:ok, Reply.encode(%Reply{error: false, reply: {:get_interface_versions_list_reply, msg}})}
  end

  def encode_reply(:get_interfaces_list, {:ok, reply}) do
    msg = %GetInterfacesListReply{
      interfaces_names: reply
    }

    {:ok, Reply.encode(%Reply{error: false, reply: {:get_interfaces_list_reply, msg}})}
  end

  def encode_reply(:get_jwt_public_key_pem, {:ok, reply}) do
    msg = %GetJWTPublicKeyPEMReply{
      jwt_public_key_pem: reply
    }

    {:ok, Reply.encode(%Reply{error: false, reply: {:get_jwt_public_key_pem_reply, msg}})}
  end

  def encode_reply(:update_jwt_public_key_pem, :ok) do
    {:ok, Reply.encode(%Reply{error: false, reply: {:generic_ok_reply, %GenericOkReply{}}})}
  end

  def encode_reply(:install_trigger, :ok) do
    {:ok, Reply.encode(%Reply{error: false, reply: {:generic_ok_reply, %GenericOkReply{}}})}
  end

  def encode_reply(:get_trigger, {:ok, reply}) do
    %{
      trigger: trigger,
      serialized_tagged_simple_triggers: serialized_tagged_simple_triggers
    } = reply

    msg = %GetTriggerReply{
      trigger_data: Trigger.encode(trigger),
      serialized_tagged_simple_triggers: serialized_tagged_simple_triggers
    }

    {:ok, Reply.encode(%Reply{error: false, reply: {:get_trigger_reply, msg}})}
  end

  def encode_reply(:get_triggers_list, {:ok, reply}) do
    msg = %GetTriggersListReply{
      triggers_names: reply
    }

    {:ok, Reply.encode(%Reply{error: false, reply: {:get_triggers_list_reply, msg}})}
  end

  def encode_reply(:delete_trigger, :ok) do
    {:ok, Reply.encode(%Reply{error: false, reply: {:generic_ok_reply, %GenericOkReply{}}})}
  end

  def encode_reply(_call_atom, {:ok, :started}) do
    msg = %GenericOkReply{
      async_operation: true
    }

    {:ok, Reply.encode(%Reply{error: false, reply: {:generic_ok_reply, msg}})}
  end

  def encode_reply(_call_atom, {:error, :retry}) do
    {:error, :retry}
  end

  def encode_reply(_call_atom, {:error, reason}) when is_atom(reason) do
    {:ok,
     Reply.encode(%Reply{
       error: true,
       reply:
         {:generic_error_reply,
          %GenericErrorReply{
            error_name: to_string(reason)
          }}
     })}
  end

  def encode_reply(_call_atom, {:error, reason}) do
    {:error, reason}
  end

  def handle_rpc(payload) do
    case Call.decode(payload) do
      %Call{call: call_tuple} when call_tuple != nil ->
        case call_tuple do
          {:get_health, %GetHealth{}} ->
            encode_reply(:get_health, Engine.get_health())

          {:install_interface,
           %InstallInterface{
             realm_name: realm_name,
             interface_json: interface_json,
             async_operation: async_operation
           }} ->
            encode_reply(
              :install_interface,
              Engine.install_interface(realm_name, interface_json, async: async_operation)
            )

          {:get_interface_source,
           %GetInterfaceSource{
             realm_name: realm_name,
             interface_name: interface_name,
             interface_major_version: interface_major_version
           }} ->
            encode_reply(
              :get_interface_source,
              Engine.interface_source(realm_name, interface_name, interface_major_version)
            )

          {:get_interface_versions_list,
           %GetInterfaceVersionsList{realm_name: realm_name, interface_name: interface_name}} ->
            encode_reply(
              :get_interface_versions_list,
              Engine.list_interface_versions(realm_name, interface_name)
            )

          {:get_interfaces_list, %GetInterfacesList{realm_name: realm_name}} ->
            encode_reply(:get_interfaces_list, Engine.get_interfaces_list(realm_name))

          {:update_interface,
           %UpdateInterface{
             realm_name: realm_name,
             interface_json: interface_json,
             async_operation: async_operation
           }} ->
            encode_reply(
              :update_interface,
              Engine.update_interface(realm_name, interface_json, async: async_operation)
            )

          {:delete_interface,
           %DeleteInterface{
             realm_name: realm_name,
             interface_name: interface_name,
             interface_major_version: interface_major_version,
             async_operation: async_operation
           }} ->
            encode_reply(
              :delete_interface,
              Engine.delete_interface(
                realm_name,
                interface_name,
                interface_major_version,
                async: async_operation
              )
            )

          {:get_jwt_public_key_pem, %GetJWTPublicKeyPEM{realm_name: realm_name}} ->
            encode_reply(:get_jwt_public_key_pem, Engine.get_jwt_public_key_pem(realm_name))

          {:update_jwt_public_key_pem,
           %UpdateJWTPublicKeyPEM{realm_name: realm_name, jwt_public_key_pem: pem}} ->
            encode_reply(
              :update_jwt_public_key_pem,
              Engine.update_jwt_public_key_pem(realm_name, pem)
            )

          {:install_trigger,
           %InstallTrigger{
             realm_name: realm_name,
             trigger_name: trigger_name,
             action: action,
             serialized_tagged_simple_triggers: serialized_tagged_simple_triggers
           }} ->
            encode_reply(
              :install_trigger,
              Engine.install_trigger(
                realm_name,
                trigger_name,
                action,
                serialized_tagged_simple_triggers
              )
            )

          {:get_trigger, %GetTrigger{realm_name: realm_name, trigger_name: trigger_name}} ->
            encode_reply(:get_trigger, Engine.get_trigger(realm_name, trigger_name))

          {:get_triggers_list, %GetTriggersList{realm_name: realm_name}} ->
            encode_reply(:get_triggers_list, Engine.get_triggers_list(realm_name))

          {:delete_trigger, %DeleteTrigger{realm_name: realm_name, trigger_name: trigger_name}} ->
            encode_reply(:delete_trigger, Engine.delete_trigger(realm_name, trigger_name))

          invalid_call ->
            Logger.warn("Received unexpected call: #{inspect(invalid_call)}")
            {:error, :unexpected_call}
        end

      invalid_message ->
        Logger.warn("Received unexpected message: #{inspect(invalid_message)}")
        {:error, :unexpected_message}
    end
  end
end
