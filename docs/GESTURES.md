# How gestures were measured

The thresholds in `helper/Sources/AirPodsCore/BeatDetector.swift` come from a guided recording, kept as `helper/Tests/AirPodsCoreTests/Fixtures/recording-1.csv`: 8,994 samples at 50 per second, with one person wearing AirPods, mostly seated. It runs as a regression test.

## Speed alone doesn't work

| Movement | Peak speed |
| --- | --- |
| Fast shake | 86–151°/s |
| Glance left or right | 81–103°/s |
| Slow nod | 43–89°/s |
| Looking at the desk | 43–49°/s |

## Rhythm does

| Movement | Gap between beats |
| --- | --- |
| Fast nods and shakes | 0.18–0.40s |
| Slow nods and shakes | 0.32–0.64s |
| Glances | 0.9s or more |
| Looking down or around | about 1.5s or more |

A beat is a swing that peaks at 30°/s or more and covers at least 4°. Three alternating beats, each within 0.41 seconds of the last, with that axis moving at least three times as far as any other, complete a gesture.

On the recording this catches 4 of 4 fast nods and 4 of 4 fast shakes, and nothing during holding still, glances, looking down, looking around, talking or walking.

## Limits

- The line between fast and slow is thin: 0.41s, with the closest slow gesture at 0.42s. A slightly slow gesture may need repeating. It can't cause a wrong answer.
- A single nod is two swings, the same as a glance, so it doesn't count.
- The rule was tuned and tested on the same recording of one person. It hasn't been tested on other people, while listening to music, or in a vehicle.
- Nodding along to a conversation is the likeliest real misread. Listening only happens during a prompt, and **Nod twice to approve** adds a second round.
