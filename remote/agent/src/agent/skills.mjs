import { readdirSync, readFileSync, statSync, realpathSync, existsSync } from 'node:fs';
import path from 'node:path';
import { scanForInjection } from './safety.mjs';

// Skills: procedures the person (or iTalk) wrote down once, loaded only when a task needs them. The model sees a one-line index of every
// skill in its instructions and reads the full text with `skill_view` when one applies (progressive disclosure: the index is cheap, the
// body costs tokens only when used). A skill is a folder with a SKILL.md (frontmatter + steps) and optional reference files beside it.

const NAME = /^[a-z0-9][a-z0-9_-]{0,63}$/;
const MAX_SKILL = 64 * 1024;

/** The small YAML subset skills use: `key: value`, `key: [a, b]`, `key:` + `- item` lines. Anything fancier is ignored, never executed. */
export function parseSkill(text) {
  const m = /^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/.exec(text);
  if (!m) return { meta: {}, body: text };
  const meta = {}; let list = null;
  for (const raw of m[1].split(/\r?\n/)) {
    if (!raw.trim() || raw.trim().startsWith('#')) continue;
    const item = /^\s+-\s+(.*)$/.exec(raw);
    if (item && list) { list.push(unquote(item[1])); continue; }
    const kv = /^([A-Za-z0-9_.-]+):\s*(.*)$/.exec(raw);
    if (!kv) continue;
    const [, key, value] = kv;
    if (value === '') { list = meta[key] = []; continue; }
    list = null;
    meta[key] = value.startsWith('[') && value.endsWith(']') ? value.slice(1, -1).split(',').map(s => unquote(s.trim())).filter(Boolean) : unquote(value);
  }
  return { meta, body: m[2] };
}
const unquote = (s) => s.replace(/^(['"])(.*)\1$/, '$2');
const asList = (v) => (Array.isArray(v) ? v : v ? [v] : []);

export class SkillLibrary {
  /** `dirs`: [{ dir, source: 'workspace'|'user'|'bundled' }] in precedence order (first wins on equal names). */
  constructor({ dirs, platform = process.platform === 'darwin' ? 'macos' : process.platform, tools = null }) {
    this.dirs = dirs; this.platform = platform; this.tools = tools;
    this.skills = new Map(); this.issues = [];
    this.scan();
  }

  scan() {
    this.skills.clear(); this.issues = [];
    for (const { dir, source } of this.dirs) {
      if (!dir || !existsSync(dir)) continue;
      for (const folder of this.#skillFolders(dir)) {
        const file = path.join(folder, 'SKILL.md');
        try {
          const size = statSync(file).size;
          if (size > MAX_SKILL) { this.issues.push({ folder, problem: 'SKILL.md is larger than 64 KB' }); continue; }
          const { meta, body } = parseSkill(readFileSync(file, 'utf8'));
          const name = String(meta.name ?? path.basename(folder));
          if (!NAME.test(name)) { this.issues.push({ folder, problem: `invalid skill name "${name}"` }); continue; }
          const platforms = asList(meta.platforms);
          if (platforms.length && !platforms.includes(this.platform)) continue;
          const requires = asList(meta.requires_tools);
          if (this.tools && requires.some(t => !this.tools.has(t))) continue;
          const scan = scanForInjection(`${meta.description ?? ''}\n${body}`);
          if (scan.flagged && source !== 'bundled') { this.issues.push({ folder, problem: `not loaded: ${scan.reasons.join('; ')}` }); continue; }
          if (this.skills.has(name)) continue;
          this.skills.set(name, { name, description: String(meta.description ?? '').slice(0, 300), source, folder, category: meta.category ?? null, tags: asList(meta.tags), version: meta.version ?? null });
        } catch (error) { this.issues.push({ folder, problem: String(error?.message ?? error).slice(0, 120) }); }
      }
    }
  }

  #skillFolders(dir) {
    const out = [];
    let entries = [];
    try { entries = readdirSync(dir, { withFileTypes: true }); } catch { return out; }
    for (const e of entries) {
      if (!e.isDirectory() || e.name.startsWith('.')) continue;
      const folder = path.join(dir, e.name);
      if (existsSync(path.join(folder, 'SKILL.md'))) out.push(folder);
      else {                                                // one level of categories: <dir>/<category>/<skill>/SKILL.md
        try { for (const s of readdirSync(folder, { withFileTypes: true })) if (s.isDirectory() && existsSync(path.join(folder, s.name, 'SKILL.md'))) out.push(path.join(folder, s.name)); } catch {}
      }
    }
    return out;
  }

  list() { return [...this.skills.values()].map(({ name, description, source, category, tags, version }) => ({ name, description, source, category, tags, version })); }

  /** The index shown in the instructions: one line per skill, bounded. */
  index({ maxChars = 3500 } = {}) {
    const lines = [];
    let used = 0, shown = 0;
    for (const s of [...this.skills.values()].sort((a, b) => a.name.localeCompare(b.name))) {
      const line = `- ${s.name}: ${s.description.replace(/\s+/g, ' ').slice(0, 110)}`;
      if (used + line.length > maxChars) break;
      lines.push(line); used += line.length + 1; shown += 1;
    }
    if (shown < this.skills.size) lines.push(`- … ${this.skills.size - shown} more (call skills_list)`);
    return lines.join('\n');
  }

  /** The full SKILL.md, or one reference file inside the skill's folder (never anything outside it). */
  view(name, file) {
    const skill = this.skills.get(String(name));
    if (!skill) return { ok: false, error: `No skill named "${name}". Call skills_list to see the available ones.` };
    let target = path.join(skill.folder, 'SKILL.md');
    if (file) {
      const wanted = path.resolve(skill.folder, String(file));
      let real; try { real = realpathSync(wanted); } catch { return { ok: false, error: `No file "${file}" in skill ${skill.name}.` }; }
      const root = realpathSync(skill.folder);
      if (real !== root && !real.startsWith(root + path.sep)) return { ok: false, error: 'That path is outside the skill.' };
      target = real;
    }
    let text;
    try { if (statSync(target).size > MAX_SKILL) return { ok: false, error: 'The file is larger than 64 KB.' }; text = readFileSync(target, 'utf8'); } catch (error) { return { ok: false, error: `Cannot read it: ${error.code ?? 'error'}.` }; }
    const files = file ? [] : this.#files(skill.folder);
    return { ok: true, name: skill.name, source: skill.source, folder: skill.folder, content: text, files };
  }

  #files(folder) {
    const out = [];
    const walk = (dir, depth) => {
      let entries = []; try { entries = readdirSync(dir, { withFileTypes: true }); } catch { return; }
      for (const e of entries) {
        if (e.name.startsWith('.') || (depth === 0 && e.name === 'SKILL.md')) continue;
        const full = path.join(dir, e.name);
        if (e.isDirectory() && depth < 2) walk(full, depth + 1);
        else if (e.isFile()) out.push(path.relative(folder, full));
        if (out.length >= 40) return;
      }
    };
    walk(folder, 0);
    return out;
  }
}
