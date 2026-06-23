/**
 * Project registry + path-allowlist guard.
 *
 * Two ways to tell the server which repos the watch may operate in:
 *
 *  - `PINCH_PROJECTS`     — an explicit allowlist of absolute repo roots. Each
 *                           one is exactly one selectable project.
 *  - `PINCH_PROJECT_ROOTS` — parent dir(s) to SCAN. Every immediate child folder
 *                           becomes a selectable project. This is the "point the
 *                           server at ~/Desktop/projects and just show me
 *                           everything" mode — the list is recomputed from disk
 *                           on every `list_projects`, so newly-cloned repos show
 *                           up the next time you open the picker, no restart.
 *
 * Together these are the load-bearing security boundary for "which directory":
 * every project the watch selects is resolved with path.resolve and verified to
 * sit under one of the explicit roots or inside one of the scan roots, so a
 * hostile `select_project` (or a `../` traversal) can never escape. Branch/dirty/
 * recency come from shelling out to git.
 */
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import path from "node:path";
import { existsSync, statSync, readdirSync } from "node:fs";
import type { ProjectRef } from "@pinch/protocol";
import { config } from "./config.js";
import { log } from "./log.js";

const execFileP = promisify(execFile);

/** Child folders we never surface as projects when scanning a parent root. */
const SKIP_DIRS = new Set(["node_modules", "dist", "build", ".Trash"]);

/**
 * Stable id for the synthetic "project root" pseudo-project — the scan root itself
 * (e.g. ~/Desktop/projects), not one of its children. Every agent SPAWNS here, with
 * cwd = the root, so it can reach every folder underneath. Selecting a real project
 * later doesn't change cwd; it just sets a soft focus hint (see attachAgent/folderHint).
 * Selecting THIS id clears that hint and returns focus to the whole root.
 */
export const ROOT_ID = "__root__";

export interface Project {
  id: string;
  name: string;
  /** Absolute, resolved path. */
  root: string;
  /** Directory mtime (ms). Cheap recency baseline for sync sorting + default(). */
  mtimeMs: number;
}

/** Derive a short stable id from a path (basename, slugified, de-duped). */
function makeId(root: string, taken: Set<string>): string {
  const base = path
    .basename(root)
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
  let id = base || "project";
  let n = 1;
  while (taken.has(id)) id = `${base}-${++n}`;
  taken.add(id);
  return id;
}

export class ProjectRegistry {
  private readonly explicitRoots: string[];
  private readonly scanRoots: string[];

  constructor(roots: string[], scanRoots: string[]) {
    this.explicitRoots = roots.map((r) => path.resolve(r));
    this.scanRoots = scanRoots.map((r) => path.resolve(r));

    for (const r of [...this.explicitRoots, ...this.scanRoots]) {
      if (!existsSync(r) || !statSync(r).isDirectory()) {
        log.warn({ root: r }, "configured project path does not exist; skipping");
      }
    }
    if (this.discover().length === 0 && !config.mock) {
      log.warn("no valid projects discovered");
    }
  }

  /**
   * Resolve the CURRENT set of projects: explicit roots + every immediate child
   * directory of each scan root. Recomputed from disk on every call so the watch
   * always sees the live contents of the folder. Ids are assigned in a stable
   * (path-sorted) pass so a project's id is identical between the `list_projects`
   * the watch renders and the `select_project` it sends back.
   */
  discover(): Project[] {
    const seen = new Set<string>();
    const out: Project[] = [];

    const add = (candidate: string) => {
      const root = path.resolve(candidate);
      if (seen.has(root)) return; // de-dupe (explicit root may also be a scanned child)
      let st;
      try {
        st = statSync(root);
      } catch {
        return; // vanished between readdir and stat
      }
      if (!st.isDirectory()) return;
      seen.add(root);
      out.push({ id: "", name: path.basename(root), root, mtimeMs: st.mtimeMs });
    };

    for (const r of this.explicitRoots) add(r);

    for (const parent of this.scanRoots) {
      let entries;
      try {
        entries = readdirSync(parent, { withFileTypes: true });
      } catch (err) {
        log.debug({ parent, err }, "scan root unreadable; skipping");
        continue;
      }
      for (const e of entries) {
        if (!e.isDirectory()) continue;
        if (e.name.startsWith(".")) continue; // skip dotfolders (.git, .config, …)
        if (SKIP_DIRS.has(e.name)) continue;
        add(path.join(parent, e.name));
      }
    }

    // Stable id assignment: sort by path first so the de-dup counter in makeId
    // is deterministic regardless of the recency sort applied for display.
    out.sort((a, b) => a.root.localeCompare(b.root));
    const taken = new Set<string>();
    for (const p of out) p.id = makeId(p.root, taken);
    return out;
  }

  /** Recency-ordered (newest dir mtime first). Used for boot log / mock listing. */
  list(): Project[] {
    return this.discover().sort((a, b) => b.mtimeMs - a.mtimeMs);
  }

  get(id: string): Project | undefined {
    if (id === ROOT_ID) return this.rootProject();
    return this.discover().find((p) => p.id === id);
  }

  /** Most recently modified project, so a fresh session lands on your latest repo. */
  default(): Project | undefined {
    return this.list()[0];
  }

  /**
   * The "project root" pseudo-project: the first scan root (e.g. ~/Desktop/projects), or — if
   * only an explicit allowlist is configured — its first entry. This is the DEFAULT spawn cwd for
   * every new agent, so a fresh agent can operate across every folder under the root and a folder
   * choice is just a soft hint. Returns undefined only if nothing is configured at all.
   */
  rootProject(): Project | undefined {
    const root = this.scanRoots[0] ?? this.explicitRoots[0];
    if (!root) return undefined;
    let mtimeMs = 0;
    try {
      mtimeMs = statSync(root).mtimeMs;
    } catch {
      return undefined;
    }
    return { id: ROOT_ID, name: path.basename(root) || "root", root, mtimeMs };
  }

  /**
   * Guard: a candidate path is allowed only if, once resolved, it sits under one
   * of the explicit roots OR inside one of the scan roots. Comparing the resolved
   * absolute path against `root + sep` defeats `../` traversal. (A scan root
   * allows any directory beneath it — that's intentional: the agent may cd into
   * any repo under the projects folder.)
   */
  isPathAllowed(candidate: string): boolean {
    const resolved = path.resolve(candidate);
    const under = (root: string) =>
      resolved === root || resolved.startsWith(root + path.sep);
    return this.explicitRoots.some(under) || this.scanRoots.some(under);
  }

  /** Resolve a ProjectRef (with live git branch/dirty) for the protocol. */
  async toRef(project: Project): Promise<ProjectRef> {
    const { branch, dirty } = await this.gitInfo(project.root);
    return {
      id: project.id,
      name: project.name,
      path: project.root,
      branch,
      dirty,
    };
  }

  /**
   * The list the watch actually renders, sorted most-recent first. Recency is the
   * later of the last git commit and the directory mtime, so both "just committed"
   * and "just touched files" bubble a repo to the top.
   */
  async listRefs(): Promise<ProjectRef[]> {
    const projects = this.discover();
    const withRecency = await Promise.all(
      projects.map(async (p) => {
        const { branch, dirty, lastCommitMs } = await this.gitInfo(p.root);
        const recency = Math.max(lastCommitMs ?? 0, p.mtimeMs);
        const ref: ProjectRef = {
          id: p.id,
          name: p.name,
          path: p.root,
          branch,
          dirty,
        };
        return { ref, recency };
      }),
    );
    withRecency.sort((a, b) => b.recency - a.recency);
    const refs = withRecency.map((w) => w.ref);
    // Surface the root itself at the TOP so the picker can return an agent's focus to the whole
    // project root (clears the soft folder hint), not just narrow it to a child.
    const root = this.rootProject();
    if (root) {
      const { branch, dirty } = await this.gitInfo(root.root);
      refs.unshift({ id: root.id, name: root.name, path: root.root, branch, dirty });
    }
    return refs;
  }

  /** Best-effort current branch + dirty flag + last-commit time. Never throws. */
  private async gitInfo(
    cwd: string,
  ): Promise<{ branch?: string; dirty?: boolean; lastCommitMs?: number }> {
    try {
      const [{ stdout: branchOut }, { stdout: statusOut }, { stdout: tsOut }] =
        await Promise.all([
          execFileP("git", ["rev-parse", "--abbrev-ref", "HEAD"], { cwd }),
          execFileP("git", ["status", "--porcelain"], { cwd }),
          execFileP("git", ["log", "-1", "--format=%ct"], { cwd }),
        ]);
      const branch = branchOut.trim() || undefined;
      const dirty = statusOut.trim().length > 0;
      const sec = Number(tsOut.trim());
      const lastCommitMs =
        Number.isFinite(sec) && sec > 0 ? sec * 1000 : undefined;
      return { branch, dirty, lastCommitMs };
    } catch (err) {
      log.debug({ cwd, err }, "git info unavailable for project");
      return {};
    }
  }
}

export const projectRegistry = new ProjectRegistry(
  config.projects,
  config.projectRoots,
);
