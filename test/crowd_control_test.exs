defmodule CrowdControlTest do
  use ExUnit.Case

  setup do
    start_supervised!({Phoenix.PubSub, name: CrowdControl.PubSub})

    start_supervised!(
      {CrowdControl,
       name: CrowdControl, pubsub: CrowdControl.PubSub, clean_period: :timer.minutes(60)}
    )

    :ok
  end

  test "increments room counter on join" do
    room = CrowdControl.find_or_start_room()
    _join_ref = CrowdControl.attempt_join(room)
    assert :ets.lookup(CrowdControl, room) == [{room, 1}]
  end

  test "decrements room counter on leave" do
    room = CrowdControl.find_or_start_room()
    join_ref = CrowdControl.attempt_join(room)
    assert :ets.lookup(CrowdControl, room) == [{room, 1}]

    CrowdControl.leave_room(room, join_ref)
    assert :ets.lookup(CrowdControl, room) == [{room, 0}]
  end

  test "decrements room counter on exit" do
    parent = self()

    user =
      spawn_link(fn ->
        room = CrowdControl.find_or_start_room()
        _join_ref = CrowdControl.attempt_join(room)
        send(parent, {self(), :joined, room})
        assert_receive {:time_to_die, ^parent}
      end)

    assert_receive {^user, :joined, room}
    assert :ets.lookup(CrowdControl, room) == [{room, 1}]

    send(user, {:time_to_die, parent})

    :timer.sleep(100)

    assert :ets.lookup(CrowdControl, room) == [{room, 0}]
  end
end
