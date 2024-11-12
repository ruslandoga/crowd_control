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
    {room, _join_ref} = CrowdControl.find_and_join_room()
    assert CrowdControl.room_counter(room) == 1
  end

  test "decrements room counter on leave" do
    {room, join_ref} = CrowdControl.find_and_join_room()
    assert CrowdControl.room_counter(room) == 1

    CrowdControl.leave_room(room, join_ref)
    assert CrowdControl.room_counter(room) == 0
  end

  test "decrements room counter on exit" do
    parent = self()

    user =
      spawn_link(fn ->
        {room, _join_ref} = CrowdControl.find_and_join_room()
        send(parent, {self(), :joined, room})
        assert_receive {:time_to_die, ^parent}
      end)

    assert_receive {^user, :joined, room}
    assert CrowdControl.room_counter(room) == 1

    send(user, {:time_to_die, parent})

    :timer.sleep(100)

    assert CrowdControl.room_counter(room) == 0
  end
end
