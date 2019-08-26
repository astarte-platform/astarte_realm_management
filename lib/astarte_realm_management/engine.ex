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

defmodule Astarte.RealmManagement.Engine do
  require Logger
  alias Astarte.Core.CQLUtils
  alias Astarte.Core.Interface, as: InterfaceDocument
  alias Astarte.Core.InterfaceDescriptor
  alias Astarte.Core.Mapping
  alias Astarte.Core.Mapping.EndpointsAutomaton
  alias Astarte.Core.Triggers.SimpleTriggersProtobuf.AMQPTriggerTarget
  alias Astarte.Core.Triggers.SimpleTriggersProtobuf.DataTrigger
  alias Astarte.Core.Triggers.SimpleTriggersProtobuf.SimpleTriggerContainer
  alias Astarte.Core.Triggers.SimpleTriggersProtobuf.TaggedSimpleTrigger
  alias Astarte.Core.Triggers.SimpleTriggersProtobuf.TriggerTargetContainer
  alias Astarte.Core.Triggers.Trigger
  alias Astarte.DataAccess.Database
  alias Astarte.DataAccess.Interface
  alias Astarte.DataAccess.Mappings
  alias Astarte.RealmManagement.Engine
  alias Astarte.RealmManagement.Queries
  alias CQEx.Client, as: DatabaseClient

  def get_health() do
    with {:ok, client} <- Database.connect(),
         :ok <- Queries.check_astarte_health(client, :each_quorum) do
      {:ok, %{status: :ready}}
    else
      {:error, :health_check_bad} ->
        with {:ok, client} <- Database.connect(),
             :ok <- Queries.check_astarte_health(client, :one) do
          {:ok, %{status: :degraded}}
        else
          {:error, :health_check_bad} ->
            {:ok, %{status: :bad}}

          {:error, :database_connection_error} ->
            {:ok, %{status: :error}}
        end

      {:error, :database_connection_error} ->
        {:ok, %{status: :error}}
    end
  end

  def install_interface(realm_name, interface_json, opts \\ []) do
    Logger.debug("Going to install a new interface on realm #{realm_name}.")

    with {:ok, client} <- Database.connect(realm_name),
         {:ok, json_obj} <- Jason.decode(interface_json),
         interface_changeset <- InterfaceDocument.changeset(%InterfaceDocument{}, json_obj),
         {:ok, interface_doc} <- Ecto.Changeset.apply_action(interface_changeset, :insert),
         interface_descriptor <- InterfaceDescriptor.from_interface(interface_doc),
         %InterfaceDescriptor{name: name, major_version: major} <- interface_descriptor,
         {:interface_avail, {:ok, false}} <-
           {:interface_avail, Queries.is_interface_major_available?(client, name, major)},
         :ok <- Queries.check_correct_casing(client, name),
         {:ok, automaton} <- EndpointsAutomaton.build(interface_doc.mappings) do
      Logger.info("Installing interface #{name} v#{Integer.to_string(major)} on #{realm_name}.")

      if opts[:async] do
        Task.start(Queries, :install_new_interface, [client, interface_doc, automaton])

        {:ok, :started}
      else
        Queries.install_new_interface(client, interface_doc, automaton)
      end
    else
      {:error, {:invalid, _invalid_str, _invalid_pos}} ->
        Logger.warn("Received invalid interface JSON: #{inspect(interface_json)}")
        {:error, :invalid_interface_document}

      {:error, %Ecto.Changeset{} = changeset} ->
        Logger.warn("Received invalid interface: #{inspect(changeset)}")
        {:error, :invalid_interface_document}

      {:error, :database_connection_error} ->
        {:error, :realm_not_found}

      {:error, :database_error} ->
        {:error, :database_error}

      {:interface_avail, {:ok, true}} ->
        {:error, :already_installed_interface}

      {:error, :invalid_name_casing} ->
        {:error, :invalid_name_casing}

      {:error, :overlapping_mappings} ->
        {:error, :overlapping_mappings}
    end
  end

  def update_interface(realm_name, interface_json, opts \\ []) do
    Logger.debug("Going to update an interface on realm #{realm_name}.")

    with {:ok, client} <- Database.connect(realm_name),
         {:ok, json_obj} <- Jason.decode(interface_json),
         interface_changeset <- InterfaceDocument.changeset(%InterfaceDocument{}, json_obj),
         {:ok, interface_doc} <- Ecto.Changeset.apply_action(interface_changeset, :insert),
         %InterfaceDocument{description: description, doc: doc} <- interface_doc,
         interface_descriptor <- InterfaceDescriptor.from_interface(interface_doc),
         %InterfaceDescriptor{name: name, major_version: major} <- interface_descriptor,
         {:interface_avail, {:ok, true}} <-
           {:interface_avail, Queries.is_interface_major_available?(client, name, major)},
         {:ok, installed_interface} <- Interface.fetch_interface_descriptor(client, name, major),
         :ok <- error_on_incompatible_descriptor(installed_interface, interface_descriptor),
         :ok <- error_on_downgrade(installed_interface, interface_descriptor),
         {:ok, new_mappings} <- extract_new_mappings(client, interface_doc),
         {:ok, automaton} <- EndpointsAutomaton.build(interface_doc.mappings) do
      Logger.info("Updating interface #{name} v#{Integer.to_string(major)} on #{realm_name}.")

      new_mappings_list = Map.values(new_mappings)

      interface_update =
        Map.merge(installed_interface, interface_descriptor, fn _k, old, new ->
          new || old
        end)

      if opts[:async] do
        Task.start_link(__MODULE__, :execute_interface_update, [
          client,
          interface_update,
          new_mappings_list,
          automaton,
          description,
          doc
        ])

        {:ok, :started}
      else
        execute_interface_update(
          client,
          interface_update,
          new_mappings_list,
          automaton,
          description,
          doc
        )
      end
    else
      {:error, {:invalid, _invalid_str, _invalid_pos}} ->
        Logger.warn("Received invalid interface JSON: #{inspect(interface_json)}")
        {:error, :invalid_interface_document}

      {:error, %Ecto.Changeset{} = changeset} ->
        Logger.warn("Received invalid interface: #{inspect(changeset)}")
        {:error, :invalid_interface_document}

      {:error, :database_connection_error} ->
        {:error, :realm_not_found}

      {:error, :database_error} ->
        {:error, :database_error}

      {:interface_avail, {:ok, false}} ->
        {:error, :interface_major_version_does_not_exist}

      {:error, :same_version} ->
        {:error, :minor_version_not_increased}

      {:error, :invalid_update} ->
        {:error, :invalid_update}

      {:error, :downgrade_not_allowed} ->
        {:error, :downgrade_not_allowed}

      {:error, :missing_endpoints} ->
        {:error, :missing_endpoints}

      {:error, :incompatible_endpoint_change} ->
        {:error, :incompatible_endpoint_change}

      {:error, :overlapping_mappings} ->
        {:error, :overlapping_mappings}
    end
  end

  def execute_interface_update(client, interface_descriptor, new_mappings, automaton, descr, doc) do
    with :ok <- Queries.update_interface_storage(client, interface_descriptor, new_mappings) do
      Queries.update_interface(client, interface_descriptor, new_mappings, automaton, descr, doc)
    end
  end

  defp error_on_downgrade(
         %InterfaceDescriptor{minor_version: installed_minor},
         %InterfaceDescriptor{minor_version: minor}
       ) do
    cond do
      installed_minor < minor ->
        :ok

      installed_minor == minor ->
        {:error, :same_version}

      installed_minor > minor ->
        {:error, :downgrade_not_allowed}
    end
  end

  defp error_on_incompatible_descriptor(installed_descriptor, new_descriptor) do
    %{
      name: name,
      major_version: major_version,
      type: type,
      ownership: ownership,
      aggregation: aggregation,
      interface_id: interface_id
    } = installed_descriptor

    with %{
           name: ^name,
           major_version: ^major_version,
           type: ^type,
           ownership: ^ownership,
           aggregation: ^aggregation,
           interface_id: ^interface_id
         } <- new_descriptor do
      :ok
    else
      incompatible_value ->
        Logger.debug("Incompatible change: #{inspect(incompatible_value)}")
        {:error, :invalid_update}
    end
  end

  # TODO: Mappings documentation changes are discarded
  defp extract_new_mappings(db_client, %{mappings: upd_mappings} = interface_doc) do
    descriptor = InterfaceDescriptor.from_interface(interface_doc)

    with {:ok, mappings} <- Mappings.fetch_interface_mappings(db_client, descriptor.interface_id) do
      upd_mappings_map =
        Enum.into(upd_mappings, %{}, fn mapping ->
          {mapping.endpoint_id, mapping}
        end)

      maybe_new_mappings =
        Enum.reduce_while(mappings, upd_mappings_map, fn mapping, acc ->
          case drop_mapping_doc(Map.get(upd_mappings_map, mapping.endpoint_id)) do
            nil ->
              {:halt, {:error, :missing_endpoints}}

            ^mapping ->
              {:cont, Map.delete(acc, mapping.endpoint_id)}

            _ ->
              {:halt, {:error, :incompatible_endpoint_change}}
          end
        end)

      if is_map(maybe_new_mappings) do
        {:ok, maybe_new_mappings}
      else
        maybe_new_mappings
      end
    end
  end

  defp drop_mapping_doc(%Mapping{} = mapping) do
    %{mapping | description: nil, doc: nil}
  end

  defp drop_mapping_doc(nil) do
    nil
  end

  def delete_interface(realm_name, name, major, opts \\ []) do
    Logger.debug("Going to delete #{name} v#{Integer.to_string(major)} on #{realm_name}.")

    with {:major, 0} <- {:major, major},
         {:ok, client} <- Database.connect(realm_name),
         {:major_is_avail, {:ok, true}} <-
           {:major_is_avail, Queries.is_interface_major_available?(client, name, 0)},
         {:devices, {:ok, false}} <-
           {:devices, Queries.is_any_device_using_interface?(client, name)},
         interface_id = CQLUtils.interface_id(name, major),
         {:triggers, {:ok, false}} <-
           {:triggers, Queries.has_interface_simple_triggers?(client, interface_id)} do
      if opts[:async] do
        Task.start_link(Engine, :execute_interface_deletion, [client, name, major])

        {:ok, :started}
      else
        Engine.execute_interface_deletion(client, name, major)
      end
    else
      {:major, _} ->
        {:error, :forbidden}

      {:major_is_avail, {:ok, false}} ->
        {:error, :interface_major_version_does_not_exist}

      {:devices, {:ok, true}} ->
        {:error, :cannot_delete_currently_used_interface}

      {:triggers, {:ok, true}} ->
        {:error, :cannot_delete_currently_used_interface}

      {_, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def execute_interface_deletion(client, name, major) do
    with {:ok, interface_row} <- Interface.retrieve_interface_row(client, name, major),
         {:ok, descriptor} <- InterfaceDescriptor.from_db_result(interface_row),
         :ok <- Queries.delete_interface_storage(client, descriptor),
         :ok <- Queries.delete_devices_with_data_on_interface(client, name) do
      Queries.delete_interface(client, name, major)
    end
  end

  def interface_source(realm_name, interface_name, major_version) do
    with {:ok, client} <- Database.connect(realm_name),
         {:ok, interface} <- Queries.fetch_interface(client, interface_name, major_version) do
      Jason.encode(interface)
    end
  end

  def list_interface_versions(realm_name, interface_name) do
    with {:ok, client} <- Database.connect(realm_name) do
      Queries.interface_available_versions(client, interface_name)
    else
      {:error, :database_connection_error} ->
        {:error, :realm_not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def get_interfaces_list(realm_name) do
    with {:ok, client} <- Database.connect(realm_name) do
      Queries.get_interfaces_list(client)
    else
      {:error, :database_connection_error} ->
        {:error, :realm_not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def get_jwt_public_key_pem(realm_name) do
    with {:ok, client} <-
           DatabaseClient.new(
             List.first(Application.get_env(:cqerl, :cassandra_nodes)),
             keyspace: realm_name
           ) do
      Queries.get_jwt_public_key_pem(client)
    else
      {:error, :shutdown} ->
        {:error, :realm_not_found}
    end
  end

  def update_jwt_public_key_pem(realm_name, jwt_public_key_pem) do
    with {:ok, client} <-
           DatabaseClient.new(
             List.first(Application.get_env(:cqerl, :cassandra_nodes)),
             keyspace: realm_name
           ) do
      Queries.update_jwt_public_key_pem(client, jwt_public_key_pem)
    else
      {:error, :shutdown} ->
        {:error, :realm_not_found}
    end
  end

  def install_trigger(realm_name, trigger_name, action, serialized_tagged_simple_triggers) do
    with {:ok, client} <- get_database_client(realm_name),
         {:exists?, {:error, :trigger_not_found}} <-
           {:exists?, Queries.retrieve_trigger_uuid(client, trigger_name)},
         simple_trigger_maps = build_simple_trigger_maps(serialized_tagged_simple_triggers),
         trigger = build_trigger(trigger_name, simple_trigger_maps, action),
         %Trigger{trigger_uuid: trigger_uuid} = trigger,
         target = build_trigger_target_container("trigger_engine", trigger_uuid),
         :ok <- validate_simple_triggers(client, simple_trigger_maps),
         # TODO: these should be batched together
         :ok <- install_simple_triggers(client, simple_trigger_maps, trigger_uuid, target) do
      Queries.install_trigger(client, trigger)
    else
      {:exists?, _} ->
        {:error, :already_installed_trigger}

      any ->
        any
    end
  end

  defp build_simple_trigger_maps(serialized_tagged_simple_triggers) do
    for serialized_tagged_simple_trigger <- serialized_tagged_simple_triggers do
      %TaggedSimpleTrigger{
        object_id: object_id,
        object_type: object_type,
        simple_trigger_container: simple_trigger_container
      } = TaggedSimpleTrigger.decode(serialized_tagged_simple_trigger)

      %{
        object_id: object_id,
        object_type: object_type,
        simple_trigger_uuid: :uuid.get_v4(),
        simple_trigger: simple_trigger_container
      }
    end
  end

  defp build_trigger(trigger_name, simple_trigger_maps, action) do
    simple_trigger_uuids =
      for simple_trigger_map <- simple_trigger_maps do
        simple_trigger_map[:simple_trigger_uuid]
      end

    %Trigger{
      trigger_uuid: :uuid.get_v4(),
      simple_triggers_uuids: simple_trigger_uuids,
      action: action,
      name: trigger_name
    }
  end

  defp build_trigger_target_container(routing_key, trigger_uuid) do
    %TriggerTargetContainer{
      trigger_target: {
        :amqp_trigger_target,
        %AMQPTriggerTarget{
          routing_key: routing_key,
          parent_trigger_id: trigger_uuid
        }
      }
    }
  end

  defp validate_simple_triggers(client, simple_trigger_maps) do
    Enum.reduce_while(simple_trigger_maps, :ok, fn
      %{simple_trigger: simple_trigger_container}, _acc ->
        %SimpleTriggerContainer{simple_trigger: {_tag, simple_trigger}} = simple_trigger_container

        case validate_simple_trigger(client, simple_trigger) do
          :ok ->
            {:cont, :ok}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
    end)
  end

  defp validate_simple_trigger(_client, %DataTrigger{interface_name: "*"}) do
    # TODO: we ignore catch-all interface triggers for now
    :ok
  end

  defp validate_simple_trigger(client, %DataTrigger{} = data_trigger) do
    %DataTrigger{
      interface_name: interface_name,
      interface_major: interface_major,
      value_match_operator: match_operator,
      match_path: match_path,
      data_trigger_type: data_trigger_type
    } = data_trigger

    # This will fail with {:error, :interface_not_found} if the interface does not exist
    with {:ok, interface} <- Queries.fetch_interface(client, interface_name, interface_major) do
      case interface.aggregation do
        :individual ->
          :ok

        :object ->
          if data_trigger_type != :INCOMING_DATA or match_operator != :ANY or match_path != "/*" do
            {:error, :invalid_object_aggregation_trigger}
          else
            :ok
          end
      end
    end
  end

  defp validate_simple_trigger(_client, _other_trigger) do
    # TODO: validate DeviceTrigger and IntrospectionTrigger
    :ok
  end

  defp install_simple_triggers(client, simple_trigger_maps, trigger_uuid, trigger_target) do
    Enum.reduce_while(simple_trigger_maps, :ok, fn
      simple_trigger_map, _acc ->
        %{
          object_id: object_id,
          object_type: object_type,
          simple_trigger_uuid: simple_trigger_uuid,
          simple_trigger: simple_trigger_container
        } = simple_trigger_map

        case Queries.install_simple_trigger(
               client,
               object_id,
               object_type,
               trigger_uuid,
               simple_trigger_uuid,
               simple_trigger_container,
               trigger_target
             ) do
          :ok ->
            {:cont, :ok}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
    end)
  end

  def get_trigger(realm_name, trigger_name) do
    with {:ok, client} <- get_database_client(realm_name),
         {:ok, %Trigger{} = trigger} <- Queries.retrieve_trigger(client, trigger_name) do
      %Trigger{
        trigger_uuid: parent_uuid,
        simple_triggers_uuids: simple_triggers_uuids
      } = trigger

      # TODO: use batch
      {everything_ok?, serialized_tagged_simple_triggers} =
        Enum.reduce(simple_triggers_uuids, {true, []}, fn
          _uuid, {false, _triggers_acc} ->
            # Avoid DB calls if we're not ok
            {false, []}

          uuid, {true, acc} ->
            case Queries.retrieve_tagged_simple_trigger(client, parent_uuid, uuid) do
              {:ok, %TaggedSimpleTrigger{} = result} ->
                {true, [TaggedSimpleTrigger.encode(result) | acc]}

              {:error, _reason} ->
                {false, []}
            end
        end)

      if everything_ok? do
        {
          :ok,
          %{
            trigger: trigger,
            serialized_tagged_simple_triggers: serialized_tagged_simple_triggers
          }
        }
      else
        {:error, :cannot_retrieve_simple_trigger}
      end
    end
  end

  def get_triggers_list(realm_name) do
    with {:ok, client} <- get_database_client(realm_name) do
      Queries.get_triggers_list(client)
    end
  end

  def delete_trigger(realm_name, trigger_name) do
    with {:ok, client} <- get_database_client(realm_name),
         {:ok, trigger} <- Queries.retrieve_trigger(client, trigger_name) do
      delete_all_succeeded =
        Enum.all?(trigger.simple_triggers_uuids, fn simple_trigger_uuid ->
          Queries.delete_simple_trigger(client, trigger.trigger_uuid, simple_trigger_uuid) == :ok
        end)

      if delete_all_succeeded do
        Queries.delete_trigger(client, trigger_name)
      else
        {:error, :cannot_delete_simple_trigger}
      end
    end
  end

  defp get_database_client(realm_name) do
    DatabaseClient.new(
      List.first(Application.get_env(:cqerl, :cassandra_nodes)),
      keyspace: realm_name
    )
  end
end
