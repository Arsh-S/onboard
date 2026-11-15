# Onboard demo video (hard limit: under 2 minutes, aim for 1:45)

What the judges asked for, and where the video answers it:
- Theme "Recreate": remake an existing AI app fully on-device      -> opening line
- Must run on a Mac with WiFi turned off                           -> turn WiFi OFF on camera, first thing
- Must use Bonsai and Argmax                                       -> name them while the settings window is up
- "When might someone need your tool without internet?"            -> closing line
- LM Studio accessibility track                                    -> hands-free section

Speakers ON (no headphones) so the mic records Onboard's voice.
Wait one beat after each request. If a take fails, repeat that line and keep going.

## 0. Open (15 s)  [settings window in front]
DO: click the WiFi icon in the menu bar and turn WiFi OFF.
SAY: "WiFi is off. This is Onboard. Cloud assistants that control your computer send your
screen and your voice to a data center. I recreated that, fully on this Mac.
Bonsai 2 from PrismML does the thinking through LM Studio. Argmax does the hearing,
the speaking, and knows my voice."

## 1. Reminder (10 s)  [hold fn]
"Remind me to call the dentist tomorrow at 9."

## 2. It asks instead of guessing (8 s)  [hold fn]
"Remind me."
(It answers: "What should the reminder say, and when?")

## 3. Calendar (8 s)  [hold fn]
"Add lunch with Bilal to my calendar Friday at noon."

## 4. Its own cursor, and it checks its work (12 s)  [click the Maintenance log window, hold fn]
"Add a line that says pump A checked."

## 5. Answers from my files, offline (10 s)  [hold fn]
"What do my notes say about filter changes?"

## 6. Hands-free, for accessibility (15 s)  [no keys]
SAY first: "No keyboard at all."
"Onboard."   (wait for the pill)
"Remind me to submit the lab report."

## 7. Voice cancel (10 s)  [no keys]
"Onboard."   then   "What does this document say?"   then, while it works:   "Cancel."

## 8. Close (12 s)
SAY: "It only obeys my voice, and it checks its work before it answers.
On a plane, in a lab with no signal, or with files that can't leave the building,
it still works. Zero bytes to the cloud. That's Onboard."

Stop recording. Check the length is under 2:00 before uploading. If it is over, cut section 3 or 5.

## Submission text (one sentence is required)
Submission from Arsh Singh
Video: <link>
GitHub: https://github.com/Arsh-S/onboard
Description: Onboard is a fully on-device agent with its own cursor that runs your Mac by voice with WiFi off, using Bonsai 2 (9B and 2B) through LM Studio and Argmax WhisperKit, SpeakerKit and TTSKit. Tracks: main and the LM Studio accessibility track.
