// lag-gen.js: Claude-Code-like terminal output for the long-tab lag repro
// (long-tab-lag.ps1). ASCII-only source: every non-ASCII character is a
// \u escape.
//
// Raw stdin, bracketed paste (?2004h), focus events (?1004h), hidden cursor
// (?25l). Every frame is a synchronized update (?2026h/l) that erases and
// redraws an 18-line dynamic region (SGR 256 and RGB colours, OSC 8 links);
// a static transcript line is appended above it every 8 frames (scrolling);
// every 3 s a full redraw clears screen and scrollback (ESC[2J ESC[3J) and
// writes 120 lines. Typed keys are echoed in the input line.
//
// usage: node lag-gen.js <seconds> [fps]
// Ends with the line "GEN-DONE <MB>MB" (written as two pieces so the echo of
// the command line itself never matches).
'use strict';

const secs = Number(process.argv[2] || 60);
const fps = Number(process.argv[3] || 60);
const out = process.stdout;
let input = '';
let bytes = 0;

function w(s) {
  bytes += Buffer.byteLength(s);
  out.write(s);
}

if (process.stdin.isTTY) process.stdin.setRawMode(true);
process.stdin.on('data', (d) => {
  input += d.toString('utf8').replace(/[\x00-\x1f]/g, '');
  if (input.length > 60) input = input.slice(-60);
});

w('\x1b[?2004h\x1b[?1004h\x1b[?25l');

// Fixed seed: every run draws the same text.
let seed = 0x2545f491;
function rnd(n) {
  seed ^= seed << 13; seed >>>= 0;
  seed ^= seed >>> 17;
  seed ^= seed << 5; seed >>>= 0;
  return seed % n;
}

const H = 18;
let frame = 0;
let drawn = 0;

function word() {
  const l = 2 + rnd(9);
  let s = '';
  for (let i = 0; i < l; i++) s += String.fromCharCode(97 + rnd(26));
  return s;
}

function line(width) {
  let s = '';
  let len = 0;
  while (len < width) {
    const t = word();
    const r = rnd(10);
    if (r === 0) s += '\x1b[38;5;' + rnd(256) + 'm' + t + '\x1b[39m';
    else if (r === 1) s += '\x1b[1;38;2;' + rnd(256) + ';' + rnd(256) + ';' + rnd(256) + 'm' + t + '\x1b[0m';
    else if (r === 2) s += '\x1b]8;;https://example.com/' + t + '\x1b\\' + t + '\x1b]8;;\x1b\\';
    else s += t;
    s += ' ';
    len += t.length + 1;
  }
  return s;
}

// Ink style: erase the previous dynamic region line by line.
function erase() {
  let s = '';
  for (let i = 0; i < drawn; i++) s += '\x1b[2K' + (i < drawn - 1 ? '\x1b[1A' : '');
  return s + '\r';
}

const spin = '|/-\\';
const rule = '\u2500'.repeat(40);
const t0 = Date.now();
const timer = setInterval(() => {
  frame++;
  let s = '\x1b[?2026h' + erase();
  if (frame % 8 === 0) s += line(100) + '\r\n';
  if (frame % (fps * 3) === 0) {
    s += '\x1b[2J\x1b[3J\x1b[H';
    for (let i = 0; i < 120; i++) s += line(100) + '\r\n';
  }
  s += '\x1b[38;5;208m' + spin[frame % 4] + '\x1b[0m Thinking\u2026 (' + frame +
    ' frames, ' + (bytes / 1e6).toFixed(1) + ' MB)\r\n';
  for (let i = 0; i < H - 3; i++) s += line(90) + '\r\n';
  s += '\x1b[2m' + rule + '\x1b[0m\r\n';
  s += '> ' + input + '\x1b[7m \x1b[0m';
  drawn = H;
  s += '\x1b[?2026l';
  w(s);
  if (Date.now() - t0 > secs * 1000) {
    clearInterval(timer);
    w('\x1b[?2004l\x1b[?1004l\x1b[?25h\r\n');
    out.write('GEN' + '-DONE ' + (bytes / 1e6).toFixed(1) + 'MB\r\n', () => process.exit(0));
  }
}, 1000 / fps);
