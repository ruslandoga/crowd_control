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

  @spec find_or_start_room() :: String.t()
  def find_or_start_room do
    find_room() || start_room()
  end

  @spec find_room(counter) :: String.t() | nil
  def find_room(counter \\ @default_counter) do
    # matches rooms with count between 15 and 100
    # generated with `:ets.fun2ms(fn {room, count} when count > 15 and count < 100 -> room end)`
    ms = [{{:"$1", :"$2"}, [{:andalso, {:>, :"$2", 15}, {:<, :"$2", 100}}], [:"$1"]}]
    limit = 5

    case :ets.select(counter, ms, limit) do
      {rooms, _continuation} ->
        Enum.random(rooms)

      :"$end_of_table" ->
        # tries to get any non-empty room (but and also non-full)
        # generated with `:ets.fun2ms(fn {room, count} when count > 0 and count < 50 -> room end)`
        ms = [{{:"$1", :"$2"}, [{:andalso, {:>, :"$2", 0}, {:<, :"$2", 50}}], [:"$1"]}]

        case :ets.select(counter, ms, limit) do
          {rooms, _continuation} -> Enum.random(rooms)
          :"$end_of_table" -> nil
        end
    end
  end

  @spec start_room :: String.t()
  def start_room do
    id =
      Base.hex_encode32(
        <<
          System.system_time(:second)::32,
          :erlang.phash2({node(), self()}, 65536)::16,
          :erlang.unique_integer()::16
        >>,
        case: :lower,
        padding: false
      )

    "room:#{id}"
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

  @doc """
  Attempts to join a room. On success, subscribes the process to the room.

  Once the caller process exits (e.g. if the caller process is a Phoenix Channel, it would exit on user disconnect),
  the room counter is automatically decremented.

  Example usage:

      defp find_and_join_room(socket) do
        room = CrowdControl.find_or_start_room()

        case CrowdControl.attempt_join(room) do
          {:ok, join_ref} ->
            push(socket, "room:joined", %{room: room})
            assign(socket, room: room, join_ref: join_ref)

          :we_are_full ->
            find_and_join_room(socket)
        end
      end

      def handle_info(:after_join, socket) do
        {:noreply, find_and_join_room(socket)}
      end

  """
  @spec attempt_join(counter, Phoenix.PubSub.t(), String.t()) :: {:ok, reference} | :we_are_full
  def attempt_join(counter \\ @default_counter, pubsub \\ @default_pubsub, room) do
    count = :ets.update_counter(counter, room, {2, 1, 100, 100}, {room, 0})

    if count < 100 do
      :ok = Phoenix.PubSub.subscribe(pubsub, room)
      {:ok, monitor(counter, room)}
    else
      :we_are_full
    end
  end

  @doc """
  Explicitly leaves a room.

  If the room is below 15 people, broadcasts a `{CrowdControl, :please_move}` message asking everyone else (in that room) to move.

  Example usage:

      defp leave_room(socket) do
        %{room: room, join_ref: join_ref} = socket.assigns
        CrowdControl.leave_room(room, join_ref)
        assign(socket, room: nil, join_ref: nil)
      end

      def handle_in("leave_room", _params, socket) do
        {:noreply, leave_room(socket)}
      end

      defp try_move_room(socket) do
        %{room: prev_room, join_ref: prev_join_ref} = socket.assigns
        new_room = CrowdControl.find_or_start_room()

        if new_room == prev_room do
          # didn't move to a new room, probably because it's the only non-empty room available right now,
          # and so we stay, we'll try again once someone else leaves
          socket
        else
          case CrowdControl.attempt_join(new_room) do
            {:ok, new_join_ref} ->
              # moved to a new room, note that this leave would trigger another `:please_move` broadcast
              # but that's ok, this way we make sure that everyone eventually moves out
              CrowdControl.leave_room(prev_room, prev_join_ref)
              push(socket, "room:moved", %{room: new_room})
              assign(socket, room: new_room, join_ref: new_join_ref)

            :we_are_full ->
              try_move_room(socket)
          end
        end
      end

      def handle_info({CrowdControl, :please_move}, socket) do
        {:noreply, try_move_room(socket)}
      end

  """
  @spec leave_room(counter, Phoenix.PubSub.t(), String.t(), reference) :: :ok
  def leave_room(counter \\ @default_counter, pubsub \\ @default_pubsub, room, join_ref) do
    demonitor(counter, join_ref)
    :ok = Phoenix.PubSub.unsubscribe(pubsub, room)
    count = :ets.update_counter(counter, room, {2, -1})

    if count < 15 do
      Phoenix.PubSub.broadcast!(pubsub, room, {CrowdControl, :please_move})
    end

    :ok
  end

  @spec monitor(counter, String.t()) :: reference
  defp monitor(counter, room) do
    GenServer.call(counter, {:monitor, self(), room})
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
  def handle_call({:monitor, pid, room}, _from, state) do
    {:reply, Process.monitor(pid, tag: {:DOWN, room}), state}
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

  def handle_info({{:DOWN, room}, ref, :process, _pid, _reason}, state) do
    %{table: table, pubsub: pubsub} = state

    Process.demonitor(ref, [:flush])
    count = :ets.update_counter(table, room, {2, -1})

    if count < 15 do
      Phoenix.PubSub.broadcast!(pubsub, room, {CrowdControl, :please_move})
    end

    {:noreply, state}
  end

  defp schedule(clean_period) do
    Process.send_after(self(), :clean, clean_period)
  end

  # cleans abandoned rooms
  defp clean(table) do
    # :ets.fun2ms(fn {room, count} when count <= 0 -> room end)
    ms = [{{:"$1", :"$2"}, [{:"=<", :"$2", 0}], [:"$1"]}]
    :ets.select_delete(table, ms)
  end
end
