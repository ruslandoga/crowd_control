Context: https://elixirforum.com/t/design-a-chat-rooms-systems-with-size-limits-that-automatically-switch-users-over-when-room-is-getting-too-big-or-too-small/67336

```console
$ mix deps.get
$ MIX_ENV=bench mix run bench/crowd_joins.exs
...
processed 10000 joins across 661 rooms in 2743ms
rooms with 100 member(s): 92
rooms with 74 member(s): 1
rooms with 68 member(s): 1
rooms with 65 member(s): 1
rooms with 62 member(s): 1
rooms with 59 member(s): 1
rooms with 1 member(s): 564 <- this uneven distribution can be improved
```
