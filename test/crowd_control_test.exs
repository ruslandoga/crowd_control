defmodule CrowdControlTest do
  use ExUnit.Case

  setup do
    start_supervised!({CrowdControl, name: CrowdControl})
    :ok
  end

  test "increments room counter on join" do
    room = CrowdControl.find_or_start_room()
    assert :ok = CrowdControl.attempt_join(room)
    assert :ets.lookup(CrowdControl.Counter, room) == [{room, 1}]
  end

  test "decrements room counter on leave" do
    room = CrowdControl.find_or_start_room()
    assert :ok = CrowdControl.attempt_join(room)
    assert :ets.lookup(CrowdControl.Counter, room) == [{room, 1}]

    assert :ok = CrowdControl.leave_room(room)

    :timer.sleep(100)

    assert :ets.lookup(CrowdControl.Counter, room) == [{room, 0}]
  end

  test "decrements room counter on exit" do
    parent = self()

    user =
      spawn_link(fn ->
        room = CrowdControl.find_or_start_room()
        assert :ok = CrowdControl.attempt_join(room)
        send(parent, {self(), :joined, room})
        assert_receive {:time_to_die, ^parent}
      end)

    assert_receive {^user, :joined, room}
    assert :ets.lookup(CrowdControl.Counter, room) == [{room, 1}]

    send(user, {:time_to_die, parent})

    :timer.sleep(100)

    assert :ets.lookup(CrowdControl.Counter, room) == [{room, 0}]
  end
end
