#!/usr/bin/env python
"""
tribe_mic.py -- speech-to-text sidecar for the tribe game.

Listens on the default microphone and appends each transcript as one line to
the file TribeVoice polls. That's the entire contract:

    mic -> STT -> append line -> user://voice_in.txt -> TribeVoice -> TribeCommand

Run it beside the game (any order; either side can restart independently):

    python tribe_mic.py

  --path PATH     write somewhere else (default: the Godot user:// dir for "tribe")
  --engine NAME   google (default) | vosk
  --list          list input devices and exit
  --device N      use input device N
  --min-words N   ignore transcripts shorter than this (default 2)
  --say "TEXT"    inject one line and exit -- NO microphone, NO network

--say exists so the mic and the bridge can fail separately. It writes through the
exact same path the real transcripts take, so with the game running:

    python tribe_mic.py --say "Ka, go get berries"

either makes Ka gather (bridge works -- any problem is your mic or the STT) or
does nothing (bridge is broken -- don't go buying a microphone). Debugging two
unknowns at once is how evenings disappear.


PRIVACY -- READ THIS ONCE, THEN DECIDE
--------------------------------------
The default engine is `recognize_google`, which UPLOADS YOUR MICROPHONE AUDIO to
Google's speech API. It is the only engine installed on this machine right now,
and it is what voice_commands.py already uses -- so this is not a new exposure,
but it is worth naming plainly: with the default engine, audio leaves the
machine. Everything ELSE in this game is local (Ollama, the Obsidian vault).

For a fully offline setup:
    pip install vosk
    # download a model, e.g. vosk-model-small-en-us-0.15, unzip next to this file
    python tribe_mic.py --engine vosk

Vosk runs entirely on-device. It is less accurate than Google on short words --
which matters here, because the roster is Ka/Bo/Ru/Wen. Your call which way to
trade that. Nothing about the game changes; only this file does.


WHY THE MIC IS ALWAYS ON AND THAT'S (PROBABLY) OK
-------------------------------------------------
Everything heard is handed to TribeCommand, which requires BOTH an addressee and
a known verb before it does anything. Ambient conversation is dropped, not
executed and not sent to the LLM. If that gate proves too loose in play, the fix
is push-to-talk, not a longer keyword list.
"""

import argparse
import os
import queue
import sys
import time

try:
    import speech_recognition as sr
except ImportError:
    sys.exit("speech_recognition is missing.  pip install SpeechRecognition pyaudio")


def default_path() -> str:
    """The Godot user:// dir for a project named "tribe". Both sides derive this
    the same way, so there is no handshake to get wrong."""
    appdata = os.environ.get("APPDATA")
    if not appdata:
        return os.path.join(os.path.dirname(os.path.abspath(__file__)), "voice_in.txt")
    return os.path.join(appdata, "Godot", "app_userdata", "tribe", "voice_in.txt")


# Devices that are NOT a microphone, however much they look like an input.
# "Stereo Mix" is the dangerous one: it's a LOOPBACK that records what your
# SPEAKERS PLAY, and on this machine Windows has it set as the DEFAULT INPUT.
# sr.Microphone() with no index takes the default -- so the sidecar happily
# recorded system audio (i.e. silence) while the user talked into a HyperX
# QuadCast it never opened. No error, no warning, just no transcripts ever.
# That cost an evening; it should cost the next person nothing.
_NOT_A_MIC = ("stereo mix", "loopback", "what u hear", "wave out", "line in",
              "sound mapper", "primary sound")


def pick_device(explicit):
    """Choose a REAL microphone. Windows' default input is not to be trusted."""
    if explicit is not None:
        return explicit
    try:
        import pyaudio
    except ImportError:
        return None
    p = pyaudio.PyAudio()
    try:
        chosen = None
        for i in range(p.get_device_count()):
            info = p.get_device_info_by_index(i)
            if int(info.get("maxInputChannels", 0)) < 1:
                continue
            name = str(info.get("name", "")).lower()
            if any(b in name for b in _NOT_A_MIC):
                continue
            if "microphone" in name or "mic " in name or name.startswith("mic"):
                chosen = i
                print(f"  auto-picked input: [{i}] {info['name']}")
                break
        if chosen is None:
            try:
                d = p.get_default_input_device_info()
                nm = str(d.get("name", "?"))
                if any(b in nm.lower() for b in _NOT_A_MIC):
                    print(f"  !! WARNING: falling back to '{nm}', which is a LOOPBACK")
                    print("  !! device, not a microphone -- it records your SPEAKERS.")
                    print("  !! Run --list and pass --device N for your real mic.")
                else:
                    print(f"  using default input: {nm}")
            except Exception:
                pass
        return chosen
    finally:
        p.terminate()


def make_recognizer(engine: str, args):
    r = sr.Recognizer()

    # ── WHY THESE VALUES: two separate truncation bugs, both measured ──
    #
    # 1) pause_threshold was 0.6 (below the 0.8 default) on the reasoning that
    #    "these are short commands". Wrong: "go get berries" came back as
    #    "go get". The natural micro-pause before the object of a sentence is
    #    longer than 0.6s, so the phrase ended after two words -- and "go get"
    #    carries no verb the parser knows ("berries" is the verb, "get" isn't),
    #    so it was silently dropped as conversation.
    #
    # 2) Then it returned "go get ber" -- cut MID-WORD, which silence detection
    #    cannot do. That's the ENERGY THRESHOLD: listen() TRIMS trailing audio it
    #    scores as silence, and adjust_for_ambient_noise had set the threshold
    #    high enough that the quiet trailing syllables of "berries" scored below
    #    it. The tail was cut off the recording BEFORE it ever reached Google.
    #    dynamic_energy_threshold=True compounds it by ratcheting the threshold
    #    UP during quiet, so it gets worse the longer the sidecar runs.
    #
    # People trail off at the end of a sentence -- that's normal speech, not a
    # defect to be filtered out. A threshold tuned to reject room noise also
    # rejects the last syllable of every command.
    r.dynamic_energy_threshold = False   # never let it ratchet up mid-session
    r.energy_threshold = args.energy
    r.pause_threshold = args.pause
    # Keep a generous tail: this is how much sub-threshold audio survives the
    # trim, and it's what protects a trailing "-ries" from being shaved off.
    r.non_speaking_duration = min(0.5, args.pause)

    if engine == "vosk":
        try:
            import vosk  # noqa: F401
        except ImportError:
            sys.exit("--engine vosk needs:  pip install vosk   (and a model unzipped nearby)")
        return r, lambda audio: r.recognize_vosk(audio)
    return r, lambda audio: r.recognize_google(audio)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--path", default=default_path())
    ap.add_argument("--engine", default="google", choices=["google", "vosk"])
    ap.add_argument("--device", type=int, default=None)
    ap.add_argument("--min-words", type=int, default=2)
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--say", default=None,
                    help="inject one line and exit (no mic, no network)")
    ap.add_argument("--test", action="store_true",
                    help="record 5s, show the live level + what STT heard, exit")
    # Tunables, because the right values depend on your mic and your room and no
    # amount of reasoning beats trying it. Defaults are set for a loud condenser
    # (HyperX QuadCast: ambient ~30, speech peaks ~250).
    # 100 sits between a measured room floor (~30-65) and measured speech
    # (~170-250) on a HyperX QuadCast. 60 was too low -- it was INSIDE the noise
    # floor, so listen() never heard silence, never ended the phrase, and shipped
    # 12s of hiss to Google ("couldn't make out words"). Run --test on your own
    # mic; it measures both floors and tells you the right number for your room.
    ap.add_argument("--energy", type=float, default=100.0,
                    help="mic level that counts as speech. Must sit ABOVE room "
                         "noise and BELOW your voice -- run --test to measure. "
                         "Default 100")
    ap.add_argument("--pause", type=float, default=1.2,
                    help="seconds of silence that end a phrase. Default 1.2")
    ap.add_argument("--phrase-limit", type=float, default=12.0,
                    help="hard cap on one utterance, seconds. Default 12")
    args = ap.parse_args()

    if args.list:
        for i, name in enumerate(sr.Microphone.list_microphone_names()):
            print(f"  [{i}] {name}")
        return

    os.makedirs(os.path.dirname(args.path), exist_ok=True)

    # Same file, same append+flush, same everything the mic path uses -- so this
    # tests the bridge and ONLY the bridge.
    if args.say:
        with open(args.path, "a", encoding="utf-8") as f:
            f.write(args.say.strip() + "\n")
            f.flush()
        print(f"  wrote to {args.path}\n  -> {args.say.strip()}")
        print("  (game running? it should react within ~0.25s)")
        return
    r, transcribe = make_recognizer(args.engine, args)
    dev = pick_device(args.device)
    mic = sr.Microphone(device_index=dev)

    # --test answers "is the mic deaf, or is the STT wrong?" -- two failures that
    # look identical from the game side (no transcript either way) and have
    # completely different fixes. Prints a live level meter so a MUTED mic is
    # obvious rather than inferred.
    if args.test:
        import audioop
        # MEASURE BOTH FLOORS, don't guess between them.
        #
        # The threshold must sit ABOVE the room and BELOW your voice. Set it too
        # low and listen() triggers on hiss, never hears silence, and hands Google
        # 12s of noise -> "couldn't make out words". Too high and it shaves the
        # quiet tail off every command -> "go get ber". I picked 60 by eye and it
        # landed IN the noise floor. Two numbers, measured, decide it -- so the
        # tool reports them instead of me guessing again.
        print("\n  [1/2] Stay QUIET for 2 seconds (measuring the room)...")
        with mic as source:
            amb = 0
            for _ in range(2):
                a = r.record(source, duration=1.0)
                amb = max(amb, audioop.rms(a.frame_data, a.sample_width))
        print(f"        room noise floor: {amb}")

        print("\n  [2/2] Now SPEAK normally for 5 seconds...\n")
        peak = 0
        with mic as source:
            for i in range(5):
                a = r.record(source, duration=1.0)
                rms = audioop.rms(a.frame_data, a.sample_width)
                peak = max(peak, rms)
                bar = "#" * min(50, rms // 20)
                print(f"   {i+1}s  RMS={rms:<6d} |{bar}")
        print(f"\n  room={amb}   speech peak={peak}")

        if peak > amb * 1.5 and peak > 40:
            # ~35% up from the floor: clear of the room, still low enough to keep
            # the trailing syllables that made "berries" into "ber".
            rec = int(amb + (peak - amb) * 0.35)
            print(f"  >>> recommended:  --energy {rec}")
            if abs(rec - args.energy) > max(15, args.energy * 0.3):
                print(f"  >>> CURRENT VALUE ({args.energy:.0f}) IS WRONG FOR THIS MIC.")
                print(f"  >>> re-run:  python tribe_mic.py --test --energy {rec}")
                print(f"  >>> then:    python tribe_mic.py --energy {rec}")
                return
            r.energy_threshold = float(rec)
        if peak < 15:
            print("  >>> DEAF. The mic captured (near-)silence while you spoke.")
            print("      - HyperX QuadCast has a TAP-TO-MUTE button on top. LED off = muted.")
            print("      - Windows: Settings > Privacy > Microphone > allow desktop apps.")
            print("      - Try another index from --list (e.g. --device 8 or 15).")
        else:
            print("  >>> The mic HEARS you. Now testing speech-to-text...")
            # NOTE: deliberately NOT calling adjust_for_ambient_noise here. It
            # sets the threshold from room noise, and on this mic that lands high
            # enough to shave the quiet tail off every command ("go get ber").
            # A fixed, low threshold keeps the whole word.
            print(f"  (energy={r.energy_threshold}  pause={r.pause_threshold}s  "
                  f"cap={args.phrase_limit}s)")
            with mic as source:
                print("  say a full command now, at your normal pace...")
                try:
                    audio = r.listen(source, timeout=10,
                                     phrase_time_limit=args.phrase_limit)
                    heard = transcribe(audio)
                    print(f"\n  STT heard: {heard!r}")
                    n = len(str(heard).split())
                    if n < 3:
                        print("  !! looks short -- if you said more than that, the tail is")
                        print("     still being trimmed. Try:  --energy 40 --pause 1.6")
                    else:
                        print("  >>> Full phrase captured. Run `python tribe_mic.py` for real.")
                except sr.WaitTimeoutError:
                    print("  !! nothing loud enough to count as speech")
                    print(f"     (threshold is {r.energy_threshold}; try --energy 30)")
                except sr.UnknownValueError:
                    print("  !! audio captured, but STT couldn't make out words")
                except sr.RequestError as e:
                    print(f"  !! Google STT unreachable: {e}")
        return

    print(f"  engine : {args.engine}" + ("   (audio is uploaded to Google)"
                                         if args.engine == "google" else "   (on-device)"))
    print(f"  writing: {args.path}")
    # Measure the room, but DON'T let it set the threshold.
    #
    # adjust_for_ambient_noise() overwrites energy_threshold based on room noise,
    # and on this mic it lands high enough to shave the quiet tail off every
    # command -- "go get berries" -> "go get ber". Calibrating here would have
    # silently undone the fixed threshold in the LIVE path while --test (which
    # doesn't calibrate) kept passing: the tuning would look correct and behave
    # wrong, which is the worst of both.
    #
    # So: measure for INFORMATION, warn if the room is louder than the threshold
    # (that's when you'd false-trigger), and otherwise leave the value alone.
    import audioop
    print("  measuring background noise -- stay quiet for a second...")
    with mic as source:
        amb = audioop.rms(r.record(source, duration=1.0).frame_data, 2)
    print(f"  ambient={amb}   threshold={r.energy_threshold:.0f}  "
          f"pause={r.pause_threshold}s")

    # A MARGIN, not just "above". This used to check `amb >= threshold`, which
    # passed at ambient=72 vs threshold=79 -- a 9% gap. Room noise isn't a flat
    # line; it fluctuates past a 9% gap constantly. listen() then triggers on
    # hiss, never hears silence, never ends the phrase, and ships 12s of noise to
    # Google, which correctly reports no words -- and the old code skipped that
    # SILENTLY. From the outside it looks like the mic "stopped working".
    #
    # Also: the room is louder with the GAME RUNNING than during --test. Speaker
    # output feeds back into a condenser mic (the TTS voices especially). So
    # calibrate here, in the conditions you'll actually play in, not in a quiet
    # room minutes earlier.
    if amb * 1.6 > r.energy_threshold:
        rec = max(int(amb * 2.0), int(amb + 60))
        print("")
        print(f"  !! TOO CLOSE. Room is {amb}, threshold is {r.energy_threshold:.0f}"
              f" -- only {(r.energy_threshold / max(amb, 1) - 1) * 100:.0f}% clear.")
        print("  !! Noise will trigger it, phrases will never end, and Google")
        print("  !! will get 12s of hiss -- which looks exactly like 'stopped working'.")
        print(f"  !! Restart with:   python tribe_mic.py --energy {rec}")
        print("")
    print("  listening. Try:  \"Ka, go get berries\"   /   \"hey everyone around me, get wood\"")
    print("  Ctrl-C to stop.\n")

    q: "queue.Queue[sr.AudioData]" = queue.Queue()
    misses = 0        # consecutive "captured audio, no words" -- see the loop

    def on_audio(_recognizer, audio):
        q.put(audio)

    # same cap as --test, or the two paths disagree about what a phrase is
    stop = r.listen_in_background(mic, on_audio, phrase_time_limit=args.phrase_limit)

    try:
        while True:
            try:
                audio = q.get(timeout=0.3)
            except queue.Empty:
                continue
            try:
                text = str(transcribe(audio)).strip()
                misses = 0
            except sr.UnknownValueError:
                # NOT silent. This used to `continue` without a word, so a mic
                # drowning in room noise looked identical to a mic that had
                # "stopped working" -- which is exactly how it was reported.
                # A run of these means the threshold is in the noise floor.
                misses += 1
                dur = len(audio.frame_data) / (audio.sample_rate * audio.sample_width)
                print(f"  .. captured {dur:.1f}s but no words in it (x{misses})")
                if misses == 3:
                    print("  !! Three in a row. The threshold is almost certainly")
                    print("  !! inside your room noise -- it keeps recording hiss.")
                    print("  !! Ctrl-C and raise it: --energy <higher>")
                continue
            except sr.RequestError as e:
                # Google's free endpoint rate-limits. This is what that looks like.
                print(f"  [stt unavailable] {e}")
                time.sleep(2.0)
                continue

            if args.engine == "vosk":
                # recognize_vosk returns a JSON blob, not a bare string
                import json
                try:
                    text = str(json.loads(text).get("text", "")).strip()
                except Exception:
                    pass

            if not text or len(text.split()) < args.min_words:
                continue

            # append + flush: TribeVoice only consumes through the last newline,
            # so a half-written line is never parsed as a command
            with open(args.path, "a", encoding="utf-8") as f:
                f.write(text + "\n")
                f.flush()
            print(f"  -> {text}")
    except KeyboardInterrupt:
        print("\n  stopping.")
    finally:
        stop(wait_for_stop=False)


if __name__ == "__main__":
    main()
