// Scroll reveal. Content is visible without JS; with JS it fades in as it enters the viewport.
(() => {
  const els = [...document.querySelectorAll('.reveal')];
  if (!('IntersectionObserver' in window)) { els.forEach((e) => e.classList.add('in')); return; }
  const io = new IntersectionObserver((entries) => {
    entries.forEach((en) => { if (en.isIntersecting) { en.target.classList.add('in'); io.unobserve(en.target); } });
  }, { rootMargin: '0px 0px -8% 0px', threshold: 0.05 });
  els.forEach((e) => io.observe(e));
  // Safety net: never leave anything hidden.
  setTimeout(() => els.forEach((e) => e.classList.add('in')), 2500);
})();

// "Say it" demo: each tab is a spoken request and what Onboard does with it
(() => {
  const demos = [
    { cmd: '"Remind me to call the dentist tomorrow at 9."', out: [
      ['tok-muted', 'hear', 'WhisperKit large-v3 turbo, on device'],
      ['tok-ok', 'act', 'Adds the reminder: Call the dentist, tomorrow at 9'],
      ['tok-header', 'say', '"Reminder added: Call the dentist, due tomorrow at 9:00 AM."'],
      ['tok-muted', 'time', 'About 3 seconds. 0 B to cloud.'] ] },
    { cmd: '"Remind me."', out: [
      ['tok-muted', 'hear', 'WhisperKit, on device'],
      ['tok-warn', 'check', 'The request names nothing to remember'],
      ['tok-header', 'say', '"What should the reminder say, and when?"'],
      ['tok-muted', 'note', 'It asks. It does not invent a reminder.'] ] },
    { cmd: '"Add a line that says pump A checked."', out: [
      ['tok-muted', 'see', 'Reads the front window as a list of controls'],
      ['tok-ok', 'think', 'Bonsai 2 9B picks one action: type into the document'],
      ['tok-ok', 'act', 'The teal cursor flies to the text area and types'],
      ['tok-ok', 'verify', 'Reads the text back: "Pump A checked" is in the document'],
      ['tok-header', 'say', '"I added the line Pump A checked to your document."'] ] },
    { cmd: 'Select a sentence, then: "Make this sound more professional."', out: [
      ['tok-muted', 'see', 'Selected text: "hey can u send me the pump numbers asap thx"'],
      ['tok-ok', 'act', 'Replaces the selection, in place'],
      ['tok-ok', 'verify', '"Hello, could you please send me the pump numbers as soon as possible?"'],
      ['tok-muted', 'time', 'About 9 seconds'] ] },
    { cmd: '"Onboard."  "What does this document say?"  "Cancel."', out: [
      ['tok-muted', 'wake', 'SpeakerKit: is this the owner\'s voice? Yes'],
      ['tok-ok', 'armed', 'The pill shows your voice while it waits'],
      ['tok-ok', 'run', 'Reading the window'],
      ['tok-warn', 'cancel', 'Heard "cancel": the run stops, the screen clears, the voice goes quiet'] ] },
    { cmd: '"Turn the WiFi off."', out: [
      ['tok-ok', 'act', 'WiFi off'],
      ['tok-header', 'say', '"WiFi is off."'],
      ['tok-muted', 'note', 'Everything else still works. Nothing ever needed the network.'] ] },
  ];
  const tabs = [...document.querySelectorAll('.cli-tab')], cmd = document.getElementById('cli-cmd'), out = document.getElementById('cli-output');
  if (!tabs.length || !cmd || !out) return;
  let run = 0, auto = null, current = 0;
  const line = (cls, k, text) => {
    const div = document.createElement('div'); div.className = 'l ' + cls;
    const a = document.createElement('span'); a.className = 'k'; a.textContent = k;
    const b = document.createElement('span'); b.textContent = text;
    div.append(a, b); return div;
  };
  const play = (i) => {
    const id = ++run; current = i;
    tabs.forEach((t, k) => { t.classList.toggle('active', k === i); t.setAttribute('aria-selected', k === i ? 'true' : 'false'); });
    cmd.textContent = ''; out.innerHTML = '';
    const d = demos[i]; let c = 0;
    const type = () => {
      if (id !== run) return;
      cmd.textContent = d.cmd.slice(0, ++c);
      if (c < d.cmd.length) return setTimeout(type, 20);
      d.out.forEach((l, k) => setTimeout(() => { if (id === run) out.appendChild(line(l[0], l[1], l[2])); }, 300 + k * 380));
    };
    type();
  };
  tabs.forEach((t, i) => t.addEventListener('click', () => { clearInterval(auto); play(i); }));
  // The first request is already in the page; start cycling once the demo has been seen.
  let started = false;
  const start = () => { if (started) return; started = true; auto = setInterval(() => play((current + 1) % demos.length), 7500); };
  if ('IntersectionObserver' in window) {
    const io = new IntersectionObserver((e) => { if (e.some((x) => x.isIntersecting)) { start(); io.disconnect(); } }, { threshold: 0.4 });
    io.observe(document.getElementById('cli-demo'));
  } else start();
})();
