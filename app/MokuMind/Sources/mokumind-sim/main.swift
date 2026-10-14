import MokuMindReplay

// Replays the scripted day through the behavior engine and prints what Moku does, second by second.
print("Moku, a scripted day (standard config; times are mm:ss from the start)")
print("")
for line in Timeline.lines(DayReplay.run(.standard)) {
    print(line)
}
