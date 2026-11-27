#!/usr/bin/env node
/**
 * stamp-trailer <msgfile> <key> <value> — append a `Key: value` trailer to a commit message file.
 *
 * Why not `git interpret-trailers`: on a ONE-paragraph message it can read the subject itself as
 * a trailer block (a subject like «Merge branch 'main' of https://…» contains «https:») and then
 * appends the trailer with NO blank line, so the trailer lands inside `git log --oneline`.
 * Rules here: the trailer joins an existing trailer block ONLY when the message has >= 2
 * paragraphs and the last one consists solely of well-formed `Token: value` lines (token = no
 * spaces); otherwise a blank line is inserted first. Trailing `#` comment lines (the editor
 * template) stay at the end, and so does everything from the scissors line down (`git commit -v`
 * puts the diff there and cuts it off afterwards — a trailer added below it would be cut too).
 * Idempotent: nothing is written if a `Key:` trailer already exists in the last paragraph.
 * The key must be a trailer token and the value a single line; anything else is refused, so a
 * setting cannot smuggle extra lines into every commit message.
 */
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';

const TRAILER = /^[A-Za-z][A-Za-z0-9-]*:[ \t]+\S/;
const escapeRx = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

/** Pure: message text → stamped text. */
export function stamp(text, key, value) {
  const lines = text.split('\n');
  // everything from the scissors line («# ------------------------ >8 ------------------------»,
  // whatever the comment character) is not part of the message
  const scissors = lines.findIndex((l) => /^. -{24} >8 -{24}$/.test(l));
  // peel the trailing comment/blank tail (editor template), keep it verbatim
  let end = scissors >= 0 ? scissors : lines.length;
  while (end > 0 && (lines[end - 1].startsWith('#') || lines[end - 1].trim() === '')) end--;
  const body = lines.slice(0, end);
  const tail = lines.slice(end);
  if (body.length === 0) return text;
  // last paragraph = lines after the last blank line
  let start = end;
  while (start > 0 && body[start - 1].trim() !== '') start--;
  const last = body.slice(start);
  const isTrailerBlock = start > 0 && last.every((l) => TRAILER.test(l) || ((l[0] === ' ' || l[0] === '\t') && l.trim() !== ''));
  const own = new RegExp(`^${escapeRx(key)}:`, 'i');
  if (isTrailerBlock && last.some((l) => own.test(l))) return text;
  const added = `${key}: ${value}`;
  const out = isTrailerBlock ? [...body, added] : [...body, '', added];
  return tail.length && !(tail.length === 1 && tail[0] === '') ? [...out, ...tail].join('\n') : `${out.join('\n')}\n`;
}

function isMain() {
  try { return fs.realpathSync(fileURLToPath(import.meta.url)) === fs.realpathSync(process.argv[1] || ''); } catch { return false; }
}

if (isMain()) {
  const [file, key, value] = process.argv.slice(2);
  try {
    if (file && key && value && !/^[A-Za-z][A-Za-z0-9-]*$/.test(key)) {
      console.error(`⚠️  stamp-trailer skipped: trailer.key must be letters, digits and dashes (got ${JSON.stringify(key).slice(0, 60)})`);
    } else if (file && key && value && /[\r\n\0]/.test(value)) {
      console.error('⚠️  stamp-trailer skipped: the agent name must be a single line');
    } else if (file && key && value) {
      const src = fs.readFileSync(file, 'utf8');
      const res = stamp(src, key, value);
      if (res !== src) fs.writeFileSync(file, res);
    }
  } catch (e) {
    console.error(`⚠️  stamp-trailer skipped: ${String(e?.message ?? e).split('\n')[0]}`);
  }
  process.exit(0);
}
