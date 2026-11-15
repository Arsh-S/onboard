// Typed tagline
(() => {
  const el = document.getElementById('typed'); if (!el) return;
  const lines = ['say it. your mac does it.', 'an agent with its own cursor.', 'wifi off. 0 bytes to the cloud.', 'it only obeys your voice.'];
  let li = 0, ci = 0, del = false;
  const tick = () => {
    const s = lines[li];
    ci += del ? -1 : 1; el.textContent = s.slice(0, ci);
    let wait = del ? 28 : 55;
    if (!del && ci === s.length) { del = true; wait = 1700; }
    else if (del && ci === 0) { del = false; li = (li + 1) % lines.length; wait = 350; }
    setTimeout(tick, wait);
  };
  tick();
})();

// "Say it" demo: each tab is a spoken request and what Onboard does with it
(() => {
  const demos = [
    { cmd: '"Remind me to call the dentist tomorrow at 9."', out: [
      ['tok-muted', 'hear    whisperkit large-v3 turbo, on device'],
      ['tok-ok', 'act     add_reminder  Call the dentist | tomorrow at 9'],
      ['tok-header', 'say     "Reminder added: Call the dentist, due tomorrow at 9:00 AM."'],
      ['tok-muted', 'time    about 3 s    cloud 0 B'] ] },
    { cmd: '"Remind me."', out: [
      ['tok-muted', 'hear    whisperkit'],
      ['tok-warn', 'check   the request names nothing to remember'],
      ['tok-header', 'say     "What should the reminder say, and when?"'],
      ['tok-muted', 'note    it asks. it does not invent a reminder.'] ] },
    { cmd: '"Add a line that says pump A checked."', out: [
      ['tok-muted', 'see     reads the front window as a list of elements'],
      ['tok-ok', 'think   bonsai 2 9b picks one action: type into the document'],
      ['tok-ok', 'act     the teal cursor flies to the text area and types'],
      ['tok-ok', 'verify  reads the text back: "Pump A checked" is in the document'],
      ['tok-header', 'say     "I added the line Pump A checked to your document."'] ] },
    { cmd: '[select a sentence]  "Make this sound more professional."', out: [
      ['tok-muted', 'see     SELECTED TEXT: "hey can u send me the pump numbers asap thx"'],
      ['tok-ok', 'act     replace_selection, in place'],
      ['tok-ok', 'verify  "Hello, could you please send me the pump numbers as soon as possible?"'],
      ['tok-muted', 'time    about 9 s'] ] },
    { cmd: '"Onboard."  ...  "What does this document say?"  ...  "Cancel."', out: [
      ['tok-muted', 'wake    speakerkit: is this the owner\'s voice? yes'],
      ['tok-ok', 'armed   the pill shows your voice while it waits'],
      ['tok-ok', 'run     reading the window'],
      ['tok-warn', 'cancel  heard "cancel": the run stops, the screen clears, the voice goes quiet'] ] },
    { cmd: '"Turn the WiFi off."', out: [
      ['tok-ok', 'act     wifi off'],
      ['tok-header', 'say     "WiFi is off."'],
      ['tok-muted', 'note    everything above still works. nothing ever needed the network.'] ] },
  ];
  const tabs = [...document.querySelectorAll('.cli-tab')], cmd = document.getElementById('cli-cmd'), out = document.getElementById('cli-output');
  if (!tabs.length || !cmd || !out) return;
  let run = 0, auto = null, current = 0;
  const play = (i) => {
    const id = ++run; current = i;
    tabs.forEach((t, k) => t.classList.toggle('active', k === i));
    cmd.textContent = ''; out.innerHTML = '';
    const d = demos[i]; let c = 0;
    const type = () => {
      if (id !== run) return;
      cmd.textContent = d.cmd.slice(0, ++c);
      if (c < d.cmd.length) return setTimeout(type, 22);
      d.out.forEach((line, k) => setTimeout(() => {
        if (id !== run) return;
        const div = document.createElement('div'); div.className = 'l show ' + line[0]; div.textContent = line[1]; out.appendChild(div);
      }, 350 + k * 420));
    };
    type();
  };
  tabs.forEach((t, i) => t.addEventListener('click', () => { clearInterval(auto); play(i); }));
  play(0);
  auto = setInterval(() => play((current + 1) % demos.length), 7000);
})();
