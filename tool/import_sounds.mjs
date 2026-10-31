// Turns the recordings in sounds/ into the news chimes and station jingles the app offers: each is made a 24 kHz mono
// 16-bit WAV at -20 LUFS in assets/sounds/, and listed in assets/sounds/sounds.json with the name the app shows.
//
//   node tool/import_sounds.mjs
//
// Runs ffmpeg in Docker (the analyzer image has it, or set FFMPEG_IMAGE). Only new or changed recordings are converted;
// a name edited in sounds.json is kept. Sounds longer than 12 seconds are left out, as the app can't play them.
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { dirname, extname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const source = join(root, "sounds"), output = join(root, "assets", "sounds"), manifest = join(output, "sounds.json");
const image = process.env.FFMPEG_IMAGE ?? "finamp-analyzer:latest";
const kinds = new Set([".mp3", ".wav", ".m4a", ".aac", ".ogg", ".flac"]);
const maxSeconds = 12, loudness = -20;

// Words that say what any of these is, not which one.
const filler = new Set(["intro", "logo", "sting", "jingle", "sound", "sounds", "effect", "sfx", "audio", "music"]);

/** A short name for the app's copy: "breakzstudios-breaking-news-intro-logo-2-314321.mp3" (a Pixabay download) ->
 * "breaking-news". */
function idOf(file) {
  const words = file.slice(0, -extname(file).length).toLowerCase().split(/[^a-z0-9]+/).filter(Boolean);
  // Pixabay names are the uploader, the title, then the sound's number.
  if (words.length > 2 && /^\d{4,}$/.test(words.at(-1))) words.splice(0, 1), words.pop();
  const short = words.filter((word) => !filler.has(word) && !/^\d+$/.test(word)).slice(0, 3);
  const id = (short.length ? short : words).join("-") || "sound";
  // Taken by the app's own choices (the built-in bells, the listener's own chime).
  return reserved.has(id) ? `${id}-sound` : id;
}

const reserved = new Set(["bells", "own", "none"]);

const nameOf = (id) => id.charAt(0).toUpperCase() + id.slice(1).replaceAll("-", " ");

function ffmpeg(args) {
  return execFileSync("docker", ["run", "--rm", "--entrypoint", "ffmpeg", "-v", `${source}:/in:ro`, "-v", `${output}:/out`,
    image, "-hide_banner", "-nostats", ...args], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"],
    env: { ...process.env, MSYS_NO_PATHCONV: "1" } });
}

function measure(args) {
  // ffmpeg writes the loudness report to stderr, which execFileSync only hands back on failure: ask for it as output.
  const text = execFileSync("docker", ["run", "--rm", "--entrypoint", "sh", "-v", `${source}:/in:ro`, "-v",
    `${output}:/out`, image, "-c", `ffmpeg -hide_banner -nostats ${args} -af ebur128 -f null - 2>&1`],
    { encoding: "utf8", env: { ...process.env, MSYS_NO_PATHCONV: "1" } });
  const integrated = [...text.matchAll(/I:\s+(-?[\d.]+) LUFS/g)].at(-1);
  const duration = text.match(/Duration: (\d+):(\d+):([\d.]+)/);
  return {
    lufs: integrated ? Number(integrated[1]) : null,
    seconds: duration ? Number(duration[1]) * 3600 + Number(duration[2]) * 60 + Number(duration[3]) : null,
  };
}

// Without the folder (a fresh checkout, say) there's nothing to compare with: the sounds already made stay as they are.
if (!existsSync(source)) {
  console.log(`No ${source}: the sounds in ${output} are left as they are.`);
  process.exit(0);
}
mkdirSync(output, { recursive: true });
const before = existsSync(manifest) ? JSON.parse(readFileSync(manifest, "utf8")) : [];
// By the recording it came from, so a name (or id) given in sounds.json stays.
const known = new Map(before.map((sound) => [sound.file, sound]));
const sounds = [];
const files = readdirSync(source).filter((file) => kinds.has(extname(file).toLowerCase())).sort();
// Every file's id, settled before any is written, so none takes another's: ids kept from before first (unless one of
// the app's own choices, taken since or from before that was checked), then new ones, numbered where they'd clash.
const ids = new Map(), taken = new Set();
for (const file of files) {
  const kept = known.get(file);
  if (kept && !reserved.has(kept.id) && !taken.has(kept.id)) ids.set(file, kept.id), taken.add(kept.id);
}
for (const file of files) {
  if (ids.has(file)) continue;
  const base = idOf(file);
  let id = base;
  for (let n = 2; taken.has(id) || reserved.has(id); n++) id = `${base}-${n}`;
  ids.set(file, id);
  taken.add(id);
}
for (const file of files) {
  const kept = known.get(file), id = ids.get(file), wav = join(output, `${id}.wav`);
  // One given a new id is made again under it.
  const old = kept?.id === id ? kept : kept && { ...kept, id, changed: null };
  const changed = statSync(join(source, file)).mtimeMs;
  if (old && old.changed === changed && existsSync(wav)) {
    sounds.push(old);
    continue;
  }
  const { seconds } = measure(`-i "/in/${file}"`);
  if (seconds == null || seconds > maxSeconds) {
    console.warn(`Skipped ${file}: ${seconds == null ? "not a recording ffmpeg can read" : `${seconds.toFixed(1)} s, over ${maxSeconds} s`}`);
    continue;
  }
  ffmpeg(["-y", "-i", `/in/${file}`, "-af", "aresample=24000:resampler=soxr", "-ac", "1", "-ar", "24000", "-c:a",
    "pcm_s16le", "/out/.raw.wav"]);
  const { lufs } = measure(`-i /out/.raw.wav`);
  const gain = lufs == null || !Number.isFinite(lufs) ? 0 : loudness - lufs;
  // A plain change of volume, never more than full scale: the sound keeps its own dynamics.
  ffmpeg(["-y", "-i", "/out/.raw.wav", "-af", `volume=${gain.toFixed(2)}dB,alimiter=limit=0.89:level=false`,
    "-c:a", "pcm_s16le", "-map_metadata", "-1", "-fflags", "+bitexact", "-flags:a", "+bitexact", `/out/${id}.wav`]);
  rmSync(join(output, ".raw.wav"), { force: true });
  sounds.push({ id, name: old?.name ?? nameOf(id), file, changed });
  console.log(`${old ? "Updated" : "Added"} ${id} (${seconds.toFixed(1)} s, ${gain >= 0 ? "+" : ""}${gain.toFixed(1)} dB)`);
}
// Recordings taken out of sounds/ leave the app too.
for (const old of before) {
  if (!sounds.some((sound) => sound.id === old.id)) {
    rmSync(join(output, `${old.id}.wav`), { force: true });
    console.log(`Removed ${old.id}`);
  }
}
writeFileSync(manifest, JSON.stringify(sounds, null, 2) + "\n");
console.log(`${sounds.length} sound(s) in ${manifest}`);
