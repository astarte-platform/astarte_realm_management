defmodule Astarte.RealmManagement.Supervisor do
  use Supervisor

  def start_link do
    Supervisor.start_link(__MODULE__, [])
  end

  def init(_) do

    amqp_opts = Application.get_env(:astarte_realm_management, :amqp_connection)
    consumer_opts = Application.get_env(:astarte_realm_management, :amqp_consumer)

    children = [
      worker(Astarte.RealmManagement.Engine, []),
      worker(AstarteCore.AMQPConnection, [amqp_opts, consumer_opts, Astarte.RealmManagement.AMQP])
    ]

    supervise(children, strategy: :one_for_one)
  end

end
