#!/usr/bin/env node
// Copies package.json's version into .claude-plugin/plugin.json and .codex-plugin/plugin.json,
// and copies the Claude manifest's skills list into the Codex manifest.
// Runs as part of `npm run version`, immediately after `changeset version`.
// With --check it changes nothing and exits 1 if anything differs.

import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const repo = join(dirname(fileURLToPath(import.meta.url)), "..");
const claudePath = join(repo, ".claude-plugin", "plugin.json");
const codexPath = join(repo, ".codex-plugin", "plugin.json");
const skillsBlock = /"skills"\s*:\s*\[[^\]]*\]/;

const { version } = JSON.parse(readFileSync(join(repo, "package.json"), "utf8"));
const check = process.argv.includes("--check");
let failed = false;

function sync(pluginPath, update, describe) {
  const source = readFileSync(pluginPath, "utf8");
  const problem = describe(JSON.parse(source));
  if (!problem) return;
  if (check) {
    console.error(`${pluginPath}: ${problem}. Run \`node scripts/sync-plugin-version.mjs\`.`);
    failed = true;
    return;
  }
  // Rewrite only the changed text, to keep the key order and the formatting.
  const updated = update(source);
  if (describe(JSON.parse(updated))) {
    console.error(`Could not update ${pluginPath}: ${problem}.`);
    process.exit(1);
  }
  writeFileSync(pluginPath, updated);
  console.log(`${pluginPath}: fixed ${problem}`);
}

for (const pluginPath of [claudePath, codexPath]) {
  sync(
    pluginPath,
    (source) => source.replace(/("version"\s*:\s*")[^"]*(")/, `$1${version}$2`),
    (plugin) => (plugin.version === version ? "" : `version is ${plugin.version}, package.json is ${version}`),
  );
}

const claudeSource = readFileSync(claudePath, "utf8");
const claudeSkills = JSON.parse(claudeSource).skills;
sync(
  codexPath,
  (source) => source.replace(skillsBlock, claudeSource.match(skillsBlock)[0]),
  (plugin) =>
    JSON.stringify(plugin.skills) === JSON.stringify(claudeSkills)
      ? ""
      : "skills list differs from .claude-plugin/plugin.json",
);

if (!failed) console.log(`Plugin manifests are in sync at ${version}.`);
process.exit(failed ? 1 : 0);
