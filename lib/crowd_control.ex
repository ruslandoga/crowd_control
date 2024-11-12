defmodule CrowdControl do
  @moduledoc """
  CrowdControl is like a Phoenix.PubSub with a gatekeeper.
  """

  use GenServer

  @default_counter __MODULE__
  @default_pubsub __MODULE__.PubSub

  @type counter :: atom

  @type start_option ::
          GenServer.option()
          # phoenix pubsub to use for message broadcasting
          | {:pubsub, Phoenix.PubSub.t()}
          # how often to clean abandoned rooms
          | {:cleanup_period, timeout}

  @spec start_link([start_option]) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, @default_counter)
    opts = Keyword.put_new(opts, :name, name)
    opts = Keyword.put_new(opts, :pubsub, @default_pubsub)
    opts = Keyword.put(opts, :table, name)

    {gen_opts, opts} =
      Keyword.split(opts, [:debug, :name, :timeout, :spawn_opts, :hibernate_after])

    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  defp room_topic(room_id) do
    room32 =
      room_id
      |> :binary.encode_unsigned()
      |> Base.encode32(case: :lower, padding: false)

    "room:" <> room32
  end

  defp room_id("room:" <> room_topic) do
    room_topic
    |> Base.decode32!(case: :lower, padding: false)
    |> :binary.decode_unsigned()
  end

  def room_counter(counter \\ @default_counter, room) do
    case :ets.lookup(counter, room_id(room)) do
      [{_, count}] -> count
      [] -> 0
    end
  end

  import Bitwise

  @spec find_and_join_room :: {String.t(), reference}
  def find_and_join_room, do: find_and_join_room(_start_at = 0b1)

  @spec find_and_join_room(counter, Phoenix.PubSub.t(), pos_integer) :: {String.t(), reference}
  def find_and_join_room(counter \\ @default_counter, pubsub \\ @default_pubsub, room_id) do
    count = :ets.update_counter(counter, room_id, {2, 1, 100, 100}, {room_id, 0})

    if count < 100 do
      room_topic = room_topic(room_id)
      :ok = Phoenix.PubSub.subscribe(pubsub, room_topic)
      {room_topic, monitor(counter, room_id)}
    else
      find_and_join_room((room_id <<< 2) + :rand.uniform(4) - 1)
    end
  end

  @doc """
  Broadcasts a message to a room.

  Example usage:

      # user sends a message, it gets re-broadcasted to the room
      def handle_in("message", message, socket) do
        CrowdControl.fastlane_broadcast_from(socket.assigns.room, "room:message", params)
        {:noreply, socket}
      end

  """
  def fastlane_broadcast_from(pubsub \\ @default_pubsub, room, topic, message) do
    # fastlaning the message (i.e. encoding only once)
    broadcast = %Phoenix.Socket.Broadcast{
      topic: room,
      event: topic,
      payload: :json.encode(message)
    }

    Phoenix.PubSub.broadcast_from!(pubsub, self(), room, broadcast)
  end

  @spec leave_room(counter, Phoenix.PubSub.t(), String.t(), reference) :: :ok
  def leave_room(counter \\ @default_counter, pubsub \\ @default_pubsub, room, join_ref) do
    demonitor(counter, join_ref)
    :ok = Phoenix.PubSub.unsubscribe(pubsub, room)
    count = :ets.update_counter(counter, room_id(room), {2, -1})

    if count < 15 do
      Phoenix.PubSub.broadcast!(pubsub, room, {CrowdControl, :please_move})
    end

    :ok
  end

  @spec monitor(counter, pos_integer) :: reference
  defp monitor(counter, room_id) do
    GenServer.call(counter, {:monitor, self(), room_id})
  end

  @spec demonitor(counter, reference) :: :ok
  defp demonitor(counter, ref) do
    GenServer.cast(counter, {:demonitor, ref})
  end

  @impl true
  def init(opts) do
    clean_period = Keyword.fetch!(opts, :clean_period)
    table = Keyword.fetch!(opts, :table)
    pubsub = Keyword.fetch!(opts, :pubsub)

    :ets.new(table, [
      :named_table,
      # NOTE: using :ordered_set might (?) improve find_room performance
      :set,
      :public,
      {:read_concurrency, true},
      {:write_concurrency, true},
      {:decentralized_counters, true}
    ])

    schedule(clean_period)
    {:ok, %{table: table, pubsub: pubsub, clean_period: clean_period}}
  end

  @impl true
  def handle_call({:monitor, pid, room_id}, _from, state) do
    {:reply, Process.monitor(pid, tag: {:DOWN, room_id}), state}
  end

  @impl true
  def handle_cast({:demonitor, ref}, state) do
    Process.demonitor(ref, [:flush])
    {:noreply, state}
  end

  @impl true
  def handle_info(:clean, state) do
    clean(state.table)
    schedule(state.clean_period)
    {:noreply, state}
  end

  def handle_info({{:DOWN, room_id}, ref, :process, _pid, _reason}, state) do
    %{table: table, pubsub: pubsub} = state

    Process.demonitor(ref, [:flush])
    count = :ets.update_counter(table, room_id, {2, -1})

    if count < 15 do
      Phoenix.PubSub.broadcast!(pubsub, room_topic(room_id), {CrowdControl, :please_move})
    end

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
