# Onboard demo plan

Story: **Sol 212.** You are a crew member at a Mars base. Earth is 21 light minutes away today, so a question to Mission Control takes more than 40 minutes to come back. The CO2 scrubber fault light just came on.

Demo data (already in place):

- Memory: `~/Library/Application Support/Onboard/memory/` (life support manual, power manual, comms rules, crew notes)
- Files: `~/Documents/OnboardDemo/consumables-log.csv` (ends at Sol 211) and `field-log.txt`

Facts the answers should match:

| Question | Correct answer, from the files |
|---|---|
| Fault light procedure | Read CO2 on panel LS-2 and log it, check the inlet filter, press RESET and wait 10 minutes, swap the bed if still above 4.0, recheck every 2 hours |
| Safe range | 2.0 to 4.0 mmHg nominal, 6.0 action limit |
| Margin at 4.1 | 1.9 mmHg under the action limit. Sorbent: 4 spare beds, 120 days |
| Who to tell | Mission Control, by incident report: reading, time, action taken |

## (a) Two minute video: shot list

Screen layout for the whole take: `field-log.txt` open in TextEdit on the left (front window), `consumables-log.csv` open in Numbers on the right. Record screen plus system audio plus mic.

| Time | Shot | You say or do | What Onboard does |
|---|---|---|---|
| 0:00 to 0:12 | Title card over a Mars photo, then the desktop | Voiceover: "A signal to Mars takes up to 24 minutes each way. Ask Earth a question and you wait 40 minutes. So the assistant has to live on board." | Nothing yet |
| 0:12 to 0:20 | Close up of the menu bar | Click the WiFi icon and turn WiFi off. Voiceover: "WiFi is off. It stays off." | Nothing yet |
| 0:20 to 0:45 | Full screen | Hold fn: **"The CO2 scrubber fault light is on, what do I do?"** | Voice pill listens. Thought bubble "Checking the manual". Speaks the steps from `habitat-manual-life-support.md` and shows the source file |
| 0:45 to 1:05 | Full screen, TextEdit in front | Hold fn: **"Log a reading of 4.1 for Sol 212 and tell me our margin."** | Window x-ray, teal cursor glides to the log, types the Sol 212 line, step dots appear. Speaks the margin: 1.9 mmHg under the limit, 120 days of sorbent |
| 1:05 to 1:15 | Full screen | Hold fn: **"Remind me to recheck in two hours."** | Adds a reminder in Reminders and confirms out loud |
| 1:15 to 1:35 | Full screen | Hold fn: **"Draft an incident report to Mission Control."** | Screen dims, approval card shows recipient, subject and body. Press Return. A Mail draft opens, not sent |
| 1:35 to 1:45 | TextEdit in front | Hold  + Control and dictate: **"Sol 212. Scrubber fault at 0940. Reading 4.1. Reset done, recheck at 1140."** | The line appears in the field log as you speak |
| 1:45 to 2:00 | Stats card, then logo | Voiceover: "Bonsai 2 9B plans each step in about 0.85 seconds. Bonsai 2 2B answers in about 0.35. Argmax hears and speaks. Zero bytes left this Mac. Built for Mars. Also for anyone who cannot send their data to a cloud, like lawyers and doctors, or does not want to pay for one." | Logo and "Muse, recreated offline." |

Recording notes:

- Do one clean take per beat and cut between them. Do not speed anything up. The real latency is the point.
- Keep the WiFi off icon visible in the menu bar in every shot.
- Before the Sol 212 log beat, click once in TextEdit so it is the front app.
- If the spoken answer runs long, cut on the first complete sentence.

## (b) Four minute live demo (top 10 round)

| Time | Beat | Line to say to Onboard | Fallback if it misses |
|---|---|---|---|
| 0:00 to 0:25 | Hook. Say the Mars numbers, then turn WiFi off in front of the judges | (none) | If the venue network is already down, open System Settings and show WiFi off |
| 0:25 to 0:55 | Manual answer | "The CO2 scrubber fault light is on, what do I do?" | Press Option-Space and type the same line. If memory returns nothing, type "search my manual for scrubber fault" |
| 0:55 to 1:30 | Act on screen | "Log a reading of 4.1 for Sol 212 and tell me our margin." | Type it in the command bar. If it types in the wrong place, press Command-Z and say "type Sol 212, CO2 4.1 in the field log" |
| 1:30 to 1:50 | Reminder | "Remind me to recheck in two hours." | Type it. If Reminders access was reset, skip to the next beat and say so |
| 1:50 to 2:20 | Approval | "Draft an incident report to Mission Control." | Type it. If Mail is not set up, stop at the approval card: the card is the point |
| 2:20 to 3:10 | **Judge's choice.** Ask a judge to name any app on the Mac and a small task | Suggested prompts if they hesitate: "Make a new note that says hello from Mars" (Notes), "How do I make this bold?" (TextEdit, it points), "Open Calculator" | If the app has poor accessibility labels, say so plainly, then offer the Notes task. Stating the limit is better than a silent stall |
| 3:10 to 3:40 | Architecture in 30 seconds (script below) | (none) | Show `docs/architecture.svg` full screen if the overlay is distracting |
| 3:40 to 4:00 | Close | (none) | (none) |

General fallbacks:

- **Voice fails in a loud room.** Use Option-Space and type. Say "it takes text too" and keep going.
- **Speech output is inaudible.** The answer is also shown on screen. Read it out.
- **"I can't reach Bonsai."** LM Studio dropped the model. Run the two `lms load` lines from the README (keep them in a terminal tab, already typed).
- **Total failure.** Play the two minute video from local disk.

### The 30 second architecture explanation

"Onboard never looks at pixels. Each step it reads the front window through the macOS accessibility tree and hands Bonsai 2 a short numbered list of what is on screen. Bonsai 2 9B returns one JSON action, and the schema only allows element numbers that exist right now, so it cannot click something that is not there. Then we read the screen again from scratch, so the model never holds a long conversation. Thinking is off, which gets a decision down to about 0.85 seconds. Bonsai 2 2B handles quick replies in about 0.35. Argmax WhisperKit hears, TTSKit speaks. Everything is on this Mac."

### Closing line

"We built it for Mars, where the cloud is 24 minutes away. It is also for anyone who cannot send their data to a cloud, like lawyers and doctors, or does not want to pay for one."

## (c) Pre-flight checklist

Do this 15 minutes before recording or going on stage, in order.

- [ ] **T7 drive plugged in.** The models live there unless they were copied to the internal disk. Confirm the drive is mounted.
- [ ] **Power adapter connected**, Low Power Mode off.
- [ ] **LM Studio models loaded.** `lms ps` shows `bonsai2-9b`, `bonsai2-2b` and `text-embedding-nomic-embed-text-v1.5`. Server running on port 1234.
- [ ] **Warm up.** Run one typed request so both Bonsai models, WhisperKit and TTSKit are in memory.
- [ ] **Permissions.** Accessibility and Microphone granted to Onboard. Reminders access granted (run the reminder beat once in advance).
- [ ] **Memory indexed.** Ask "what is the safe CO2 range?" and check that it answers 2.0 to 4.0.
- [ ] **Demo files reset.** `consumables-log.csv` ends at Sol 211. `field-log.txt` has no Sol 212 line. Delete the rehearsal reminder and close any rehearsal Mail draft.
- [ ] **Windows arranged.** TextEdit with `field-log.txt` on the left and in front, Numbers with the consumables log on the right. Everything else closed.
- [ ] **WiFi off.** Bluetooth off too if no accessory needs it. Unplug Ethernet adapters.
- [ ] **Do Not Disturb on.** No banners over the demo.
- [ ] **Sound on.** Output volume around 70 percent, correct output device, mic input checked.
- [ ] **Display.** Mirroring set, resolution checked on the projector, Dock hidden or small.
- [ ] **Backup.** The two minute video is on the internal disk and opens without a network.
