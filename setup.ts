#!/usr/bin/env bun

import {
  copyFileSync,
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  renameSync,
  writeFileSync,
} from "node:fs";
import { dirname, isAbsolute, resolve, sep } from "node:path";
import { spawnSync } from "node:child_process";
import {
  array,
  boolean,
  fallback,
  nonEmpty,
  object,
  optional,
  parse,
  pipe,
  record,
  safeParse,
  string,
  unknown,
  type InferOutput,
} from "./vendor/valibot/index.js";

type CommandResult = {
  ok: boolean;
  stdout: string;
  stderr: string;
};

const worktreeEvent = object({
  data: object({
    worktree: object({
      path: pipe(string(), nonEmpty()),
      branch: fallback(string(), ""),
    }),
  }),
});

const configuration = object({ projects: optional(record(string(), unknown())) });

const projectConfiguration = object({
  "fresh-base": fallback(boolean(), false),
  copy: optional(array(string("copy must be an array of relative file paths"), "copy must be an array of relative file paths")),
  steps: optional(array(pipe(string("steps must be an array of non-empty shell commands"), nonEmpty("steps must be an array of non-empty shell commands")), "steps must be an array of non-empty shell commands")),
});

type ProjectConfig = InferOutput<typeof projectConfiguration>;

const TAG = "[worktree-setup]";

function log(message: string): void {
  process.stdout.write(`${TAG} ${message}\n`);
}

function run(command: string, args: string[], cwd?: string): CommandResult {
  const result = spawnSync(command, args, {
    cwd,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });

  if (result.error || result.status === null) {
    throw new Error(`${command} could not run: ${result.error?.message ?? "killed by signal"}`);
  }

  return {
    ok: result.status === 0,
    stdout: (result.stdout ?? "").trim(),
    stderr: (result.stderr ?? "").trim(),
  };
}

function git(cwd: string, ...args: string[]): CommandResult {
  return run("git", ["-C", cwd, ...args]);
}

function recordGeneratedWorktree(worktree: string, branch: string): void {
  if (!branch) return;

  const marker = git(
    worktree,
    "rev-parse",
    "--path-format=absolute",
    "--git-path",
    "herdr-generated-worktree",
  );

  if (!marker.ok || !marker.stdout) {
    throw new Error(`cannot resolve generated-worktree marker: ${marker.stderr}`);
  }

  const temporary = `${marker.stdout}.tmp-${process.pid}`;
  writeFileSync(temporary, `${branch}\n`, { encoding: "utf8", mode: 0o600 });
  renameSync(temporary, marker.stdout);
}

function eventWorktree() {
  const raw = process.env.HERDR_PLUGIN_EVENT_JSON;

  if (!raw) throw new Error("HERDR_PLUGIN_EVENT_JSON is not set");

  let event;

  try {
    event = JSON.parse(raw);
  } catch (error) {
    throw new Error(`invalid HERDR_PLUGIN_EVENT_JSON: ${String(error)}`);
  }

  const decoded = safeParse(worktreeEvent, event);

  if (!decoded.success) {
    throw new Error("worktree.created event has no worktree path");
  }

  return decoded.output.data.worktree;
}

function mainRepository(worktree: string): string {
  const result = git(worktree, "worktree", "list", "--porcelain");

  if (!result.ok) throw new Error(`cannot list Git worktrees: ${result.stderr}`);
  const line = result.stdout.split("\n").find((candidate) => candidate.startsWith("worktree "));

  if (!line) throw new Error("Git returned no primary worktree");

  return line.slice("worktree ".length);
}

function repositoryKey(mainRepo: string): string {
  const result = git(mainRepo, "remote", "get-url", "origin");

  if (!result.ok || !result.stdout) throw new Error("repository has no origin remote");
  const remote = result.stdout.replace(/\/$/, "").replace(/\.git$/, "");

  const scp = remote.match(/^[^@]+@([^:]+):(.+)$/);

  if (scp) return `${scp[1]}/${scp[2]}`;

  try {
    const url = new URL(remote);

    return `${url.hostname}${url.pathname}`.replace(/\/$/, "");
  } catch {
    return remote;
  }
}

function loadProject(key: string): ProjectConfig | undefined {
  const configDir = process.env.HERDR_PLUGIN_CONFIG_DIR;

  if (!configDir) throw new Error("HERDR_PLUGIN_CONFIG_DIR is not set");
  const path = resolve(configDir, "config.toml");
  const parsed = parse(configuration, Bun.TOML.parse(readFileSync(path, "utf8")));
  const project = parsed.projects?.[key];

  if (!project) return undefined;

  return parse(projectConfiguration, project);
}

function refreshFreshBranch(worktree: string, branch: string): void {
  if (!branch) {
    log("fresh-base skipped: detached worktree");

    return;
  }

  if (git(worktree, "rev-parse", "--verify", "--quiet", `${branch}@{upstream}`).ok) {
    log(`fresh-base skipped: ${branch} tracks an upstream`);

    return;
  }

  if (git(worktree, "show-ref", "--verify", "--quiet", `refs/remotes/origin/${branch}`).ok) {
    log(`fresh-base skipped: origin/${branch} exists`);

    return;
  }

  const head = git(worktree, "rev-parse", "HEAD");

  if (!head.ok) throw new Error(`cannot resolve worktree HEAD: ${head.stderr}`);

  const containing = git(
    worktree,
    "for-each-ref",
    "--format=%(refname)",
    "--contains",
    head.stdout,
    "refs/heads",
  );

  if (!containing.ok) throw new Error(`cannot inspect local branches: ${containing.stderr}`);

  const hasOtherBranch = containing.stdout
    .split("\n")
    .some((ref) => ref && ref !== `refs/heads/${branch}`);

  if (!hasOtherBranch) {
    log("fresh-base skipped: branch has commits found on no other local branch");

    return;
  }

  const fetched = git(worktree, "fetch", "origin", "HEAD");

  if (!fetched.ok) {
    log("fresh-base skipped: could not fetch origin HEAD");

    return;
  }

  const status = git(worktree, "status", "--porcelain");

  if (!status.ok) throw new Error(`cannot inspect worktree status: ${status.stderr}`);

  if (status.stdout) {
    log("fresh-base skipped: worktree has uncommitted files");

    return;
  }

  const target = git(worktree, "rev-parse", "FETCH_HEAD");
  const reset = git(worktree, "reset", "--hard", "FETCH_HEAD");

  if (!reset.ok) throw new Error(`cannot reset to origin HEAD: ${reset.stderr}`);
  log(`fresh-base reset ${branch} to ${target.stdout.slice(0, 12)}`);
}

function safeRelativePath(value: string): boolean {
  return (
    value.length > 0 &&
    !isAbsolute(value) &&
    !value.split(/[\\/]/).some((part) => part === "" || part === "." || part === "..")
  );
}

function rejectDestinationSymlinks(worktree: string, file: string): void {
  let current = resolve(worktree);

  for (const part of file.split(sep)) {
    current = resolve(current, part);
    const stat = lstatSync(current, { throwIfNoEntry: false });

    if (!stat) return;

    if (stat.isSymbolicLink()) throw new Error(`copy destination is a symbolic link: ${file}`);
  }
}

function copyConfiguredFiles(mainRepo: string, worktree: string, files: ProjectConfig["copy"]): void {
  if (files === undefined) return;

  for (const file of files) {
    if (!safeRelativePath(file)) throw new Error(`unsafe copy path: ${file}`);
    const source = resolve(mainRepo, file);
    const target = resolve(worktree, file);

    if (!target.startsWith(`${resolve(worktree)}${sep}`)) {
      throw new Error(`copy path escapes worktree: ${file}`);
    }

    if (!existsSync(source)) continue;

    rejectDestinationSymlinks(worktree, file);

    if (existsSync(target)) continue;
    const sourceStat = lstatSync(source);

    if (!sourceStat.isFile() || sourceStat.isSymbolicLink()) {
      throw new Error(`copy source is not a regular file: ${file}`);
    }

    mkdirSync(dirname(target), { recursive: true });
    copyFileSync(source, target);
    log(`copied ${file}`);
  }
}

function runSteps(worktree: string, mainRepo: string, branch: string, steps: ProjectConfig["steps"]): void {
  if (steps === undefined) return;

  const env = {
    ...process.env,
    HERDR_MAIN_REPO: mainRepo,
    HERDR_WORKTREE: worktree,
    HERDR_BRANCH: branch,
  };

  for (const step of steps) {
    log(`$ ${step}`);
    const result = spawnSync("/bin/sh", ["-c", step], { cwd: worktree, env, stdio: "inherit" });

    if (result.error || result.status !== 0) {
      throw new Error(`setup step failed (${result.status ?? "signal"}): ${step}`);
    }
  }
}

function main(): void {
  const worktree = eventWorktree();
  recordGeneratedWorktree(worktree.path, worktree.branch);
  const mainRepo = mainRepository(worktree.path);
  const key = repositoryKey(mainRepo);
  const project = loadProject(key);

  if (!project) {
    log(`no configuration for ${key}`);

    return;
  }

  if (project["fresh-base"] === true) refreshFreshBranch(worktree.path, worktree.branch);
  copyConfiguredFiles(mainRepo, worktree.path, project.copy);
  runSteps(worktree.path, mainRepo, worktree.branch, project.steps);
}

try {
  main();
} catch (error) {
  process.stderr.write(`${TAG} error: ${error instanceof Error ? error.message : String(error)}\n`);
  process.exit(1);
}
