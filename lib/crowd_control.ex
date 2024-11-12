defmodule CrowdControl do
  @moduledoc """
  CrowdControl is like a Phoenix.PubSub with a gatekeeper.
  """

  @default_counter_table __MODULE__.Counter
  @default_pubsub __MODULE__.PubSub

  def child_spec(opts) do
    CrowdControl.Supervisor.child_spec(opts)
  end

  def find_or_start_room do
    find_room() || start_room()
  end

  def find_room(table \\ @default_counter_table) do
    # matches rooms with count between 15 and 100
    # :ets.fun2ms(fn {room, count} when count > 15 and count < 100 -> room end)
    ms = [{{:"$1", :"$2"}, [{:andalso, {:>, :"$2", 15}, {:<, :"$2", 100}}], [:"$1"]}]

    case :ets.select(table, ms) do
      [] ->
        # tries to get any non-empty room
        # :ets.fun2ms(fn {room, count} when count > 0 and count < 100 -> room end)
        ms = [{{:"$1", :"$2"}, [{:andalso, {:>, :"$2", 0}, {:<, :"$2", 100}}], [:"$1"]}]

        case :ets.select(table, ms) do
          [] -> nil
          # can be something else, random is just an example, maybe :ets.select(table, ms, _limit = 1) can be used to get just one room
          rooms -> Enum.random(rooms)
        end

      rooms ->
        # same as above
        Enum.random(rooms)
    end
  end

  def start_room do
    "room:#{:rand.uniform(100_000)}"
  end

  def attempt_join(table \\ @default_counter_table, pubsub \\ @default_pubsub, room) do
    count = :ets.update_counter(table, room, {2, 1, 100, 100}, {room, 0})

    if count < 100 do
      :ok = Phoenix.PubSub.subscribe(pubsub, room)
    else
      :we_are_full
    end
  end

  def leave_room(pubsub \\ @default_pubsub, room) do
    :ok = Phoenix.PubSub.unsubscribe(pubsub, room)
  end
end

defmodule CrowdControl.Supervisor do
  @moduledoc false
  use Supervisor

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    Supervisor.start_link(__MODULE__, opts, name: Module.concat(name, "Supervisor"))
  end

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    adapter_name = Module.concat(name, "Adapter")
    counter_name = Module.concat(name, "Counter")
    counter_clean_period = Keyword.get(opts, :clean_period, :timer.seconds(60))
    registry_name = Module.concat(name, "PubSub")

    # custom pubsub to monitor those who joined rooms and decrement counters when they exit
    # adapted from https://github.com/phoenixframework/phoenix_pubsub/blob/v2.1.3/lib/phoenix/pubsub/supervisor.ex
    # alternative is to monitor in the counter, which is probably simpler, but I wanted to explore this PubSub approach
    registry = [
      meta: [pubsub: {Phoenix.PubSub.PG2, adapter_name}],
      partitions: System.schedulers_online() |> Kernel./(4) |> Float.ceil() |> trunc(),
      keys: :duplicate,
      name: registry_name,
      # the important bit, this let's us decrement room counter when the user disconnects
      listeners: [counter_name]
    ]

    children = [
      {Registry, registry},
      {Phoenix.PubSub.PG2, name: registry_name, adapter_name: adapter_name},
      {CrowdControl.Counter,
       name: counter_name, table: counter_name, clean_period: counter_clean_period}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end

defmodule CrowdControl.Counter do
  @moduledoc false
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
  end

  @impl true
  def init(opts) do
    clean_period = Keyword.fetch!(opts, :clean_period)
    table = Keyword.fetch!(opts, :table)

    :ets.new(table, [
      :named_table,
      # can be ordered set if find_room should prefer fuller / emptier rooms
      :set,
      :public,
      {:read_concurrency, true},
      {:write_concurrency, true},
      {:decentralized_counters, true}
    ])

    schedule(clean_period)
    {:ok, %{table: table, clean_period: clean_period}}
  end

  @impl true
  def handle_info({:register, _pubsub, _room, _partition, _meta}, state) do
    {:noreply, state}
  end

  def handle_info({:unregister, pubsub, room, _partition}, state) do
    count = :ets.update_counter(state.table, room, {2, -1})

    if count < 15 do
      Phoenix.PubSub.broadcast!(pubsub, room, {CrowdControl, :please_move})
    end

    {:noreply, state}
  end

  def handle_info(:clean, state) do
    clean(state.table)
    schedule(state.clean_period)
    {:noreply, state}
  end

  defp schedule(clean_period) do
    Process.send_after(self(), :clean, clean_period)
  end

  # cleans abandoned rooms
  defp clean(table) do
    # :ets.fun2ms(fn {room, count} when count <= 0 -> room end)
    ms = [{{:"$1", :"$2"}, [{:<=, :"$2", 0}], [:"$1"]}]
    :ets.select_delete(table, ms)
  end
end
