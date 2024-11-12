children = [
  {Phoenix.PubSub, name: CrowdControl.PubSub},
  {CrowdControl,
   name: CrowdControl, pubsub: CrowdControl.PubSub, clean_period: :timer.minutes(60)}
]

Supervisor.start_link(children, strategy: :one_for_one)

parent = self()
users_count = 10000

started_at = System.monotonic_time(:millisecond)

Enum.each(1..users_count, fn user_id ->
  spawn_link(fn ->
    {room, _join_ref} = CrowdControl.find_and_join_room()
    IO.puts(IO.ANSI.green() <> "user #{user_id} joined room #{room}" <> IO.ANSI.reset())
    send(parent, {user_id, :joined, room})
    :timer.sleep(:timer.minutes(60))
  end)
end)

Enum.each(1..users_count, fn _ ->
  receive do
    {_user_id, :joined, _room} -> :ok
  end
end)

finished_at = System.monotonic_time(:millisecond)

rooms = :ets.tab2list(CrowdControl)

IO.puts(
  "processed #{users_count} joins across #{length(rooms)} rooms in #{finished_at - started_at}ms"
)

histogram =
  Enum.group_by(
    rooms,
    fn {_, count} -> count end,
    fn {room, _} -> room end
  )
  |> Enum.map(fn {count, rooms} -> {count, length(rooms)} end)
  |> Enum.sort_by(fn {count, _} -> count end, :desc)

histogram
|> Enum.map(fn {count, rooms} -> "rooms with #{count} member(s): #{rooms}" end)
|> Enum.join("\n")
|> IO.puts()
