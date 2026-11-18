#!/usr/bin/env python3
"""Generate an original 96 BPM C–Am–F–G practice backing; stdlib only."""
import array
import math
from pathlib import Path
import random
import wave

rate = 22_050
beat = 60 / 96
bars = 8
duration = bars * 4 * beat
audio = [0.0] * int(rate * duration)
random.seed(410)
chords = [(48, 52, 55), (45, 48, 52), (41, 45, 48), (43, 47, 50)]

for bar in range(bars):
    notes = chords[bar % 4]
    start = bar * 4 * beat
    for frame in range(int(4 * beat * rate)):
        t = frame / rate
        env = min(1, t / 0.06) * min(1, (4 * beat - t) / 0.20)
        pad = sum(math.sin(2 * math.pi * 440 * 2 ** ((note - 69) / 12) * t)
                  for note in notes) / 3
        audio[int(start * rate) + frame] += pad * 0.10 * env
    for pulse in range(4):
        offset = int((start + pulse * beat) * rate)
        freq = 440 * 2 ** ((notes[0] - 12 - 69) / 12)
        for frame in range(int(beat * 0.85 * rate)):
            t = frame / rate
            env = min(1, t / 0.008) * math.exp(-t * 6)
            bass = math.sin(2 * math.pi * freq * t) * 0.25 * env
            kick = math.sin(2 * math.pi * (48 * t + 5 * (1 - math.exp(-t * 20))))
            audio[offset + frame] += bass + kick * math.exp(-t * 25) * 0.22
    for pulse in range(8):
        offset = int((start + pulse * beat / 2) * rate)
        previous = 0.0
        for frame in range(int(0.065 * rate)):
            value = random.uniform(-1, 1)
            noise = value - previous
            previous = value
            audio[offset + frame] += noise * math.exp(-frame / rate * 75) * 0.035

for frame in range(len(audio)):
    fade = min(1, frame / (rate * 0.01), (len(audio) - 1 - frame) / (rate * 0.06))
    audio[frame] *= max(0, fade)
peak = max(abs(value) for value in audio)
pcm = array.array('h', (round(value / max(1, peak) * 29_000) for value in audio))
output = Path(__file__).resolve().parents[1] / 'Samples' / 'Demo-C-Am-F-G-96bpm.wav'
output.parent.mkdir(parents=True, exist_ok=True)
with wave.open(str(output), 'wb') as wav:
    wav.setnchannels(1)
    wav.setsampwidth(2)
    wav.setframerate(rate)
    wav.writeframes(pcm.tobytes())
print(f'{output.name}: {duration:.1f}s, {rate}Hz, mono PCM16, peak {peak:.3f}')
