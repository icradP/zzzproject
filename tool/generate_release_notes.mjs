import { execFileSync } from "node:child_process";
import { readFile, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

export const catalogPath = "assets/data/im_release_notes.json";
export const generatedPath = "lib/src/im/data/im_release_notes.g.dart";
export const maxDeployItems = 8;

const skipSubject =
  /^(docs|test|chore|ci|style|refactor)(\(.+\))?:|^(feat|fix)\(deploy\):|^record |^mark |^keep |^retry ci/i;

export function parsePubspecVersion(text) {
  const match = /^version:\s*([0-9]+\.[0-9]+\.[0-9]+)/m.exec(text);
  if (!match) {
    throw new Error("pubspec.yaml does not contain a X.Y.Z version.");
  }
  return match[1];
}

export function dartString(value) {
  return `'${String(value)
    .replaceAll("\\", "\\\\")
    .replaceAll("'", "\\'")
    .replaceAll("$", "\\$")}'`;
}

export function humanizeSubject(subject) {
  const stripped = String(subject)
    .trim()
    .replace(/^(feat|fix|perf|revert)(\([^)]*\))?:\s*/i, "");
  if (!stripped) return "";
  return stripped.charAt(0).toUpperCase() + stripped.slice(1);
}

export function selectCommitSubjects(subjects, limit = maxDeployItems) {
  const items = [];
  const seen = new Set();
  for (const subject of subjects) {
    const trimmed = String(subject).trim();
    if (!trimmed || skipSubject.test(trimmed)) continue;
    const item = humanizeSubject(trimmed);
    if (!item || seen.has(item.toLowerCase())) continue;
    seen.add(item.toLowerCase());
    items.push(item.endsWith(".") ? item : `${item}.`);
    if (items.length >= limit) break;
  }
  return items;
}

export function buildCatalog({
  catalog,
  pubspecVersion,
  releaseId = "",
  commitSubjects = [],
  date = new Date(),
}) {
  if (catalog.current_version !== pubspecVersion) {
    throw new Error(
      `release notes current_version ${catalog.current_version} does not match pubspec ${pubspecVersion}`,
    );
  }
  const history = (catalog.releases || []).map((release) => ({
    id: release.id || release.version,
    version: release.version,
    title: release.title,
    items: [...release.items],
  }));
  if (history.length === 0 || history[0].version !== pubspecVersion) {
    throw new Error(
      "release notes catalog must start with the current pubspec version.",
    );
  }

  const stamp = String(releaseId || "").trim();
  if (!stamp) {
    return {
      current_version: pubspecVersion,
      current_id: pubspecVersion,
      releases: history,
    };
  }

  const deployItems = selectCommitSubjects(commitSubjects);
  const current = {
    id: `${pubspecVersion}+${stamp}`,
    version: pubspecVersion,
    title: `Updated ${formatDate(date)}`,
    items:
      deployItems.length > 0
        ? deployItems
        : [`Production build ${stamp} is now live on icrad.ltd.`],
  };
  const remaining = history.filter((release) => release.id !== current.id);
  return {
    current_version: pubspecVersion,
    current_id: current.id,
    releases: [current, ...remaining],
  };
}

export function renderDart(catalog) {
  const releases = catalog.releases
    .map((release) => {
      const items = release.items
        .map((item) => `        ${dartString(item)},`)
        .join("\n");
      return `    ImReleaseNote(
      id: ${dartString(release.id)},
      version: ${dartString(release.version)},
      title: ${dartString(release.title)},
      items: [
${items}
      ],
    )`;
    })
    .join(",\n");

  return `part of 'im_release_notes.dart';

const _currentVersion = ${dartString(catalog.current_version)};
const _currentId = ${dartString(catalog.current_id)};
const _releases = <ImReleaseNote>[
${releases},
];
`;
}

export async function loadCatalog(root) {
  return JSON.parse(await readFile(resolve(root, catalogPath), "utf8"));
}

export function readCommitSubjects(root, sinceRef) {
  const args = ["-C", root, "log", "--no-merges", "--format=%s"];
  if (sinceRef) args.push(`${sinceRef}..HEAD`);
  return execFileSync("git", args, { encoding: "utf8" })
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean);
}

export function lastCatalogCommit(root) {
  try {
    return execFileSync(
      "git",
      ["-C", root, "log", "-1", "--format=%H", "--", catalogPath],
      { encoding: "utf8" },
    ).trim();
  } catch {
    return "";
  }
}

export async function generateReleaseNotes({
  root,
  releaseId = "",
  apply = false,
  check = false,
}) {
  const pubspecVersion = parsePubspecVersion(
    await readFile(resolve(root, "pubspec.yaml"), "utf8"),
  );
  const source = await loadCatalog(root);
  const since = releaseId ? lastCatalogCommit(root) : "";
  const commitSubjects = releaseId ? readCommitSubjects(root, since) : [];
  const catalog = buildCatalog({
    catalog: source,
    pubspecVersion,
    releaseId,
    commitSubjects,
  });
  const dart = renderDart(catalog);
  const output = resolve(root, generatedPath);
  if (check) {
    const existing = await readFile(output, "utf8");
    if (existing !== dart) {
      throw new Error(`${generatedPath} is stale; run the generator with --apply.`);
    }
  }
  if (apply) {
    await writeFile(output, dart, "utf8");
  }
  return catalog;
}

function formatDate(date) {
  const months = [
    "Jan",
    "Feb",
    "Mar",
    "Apr",
    "May",
    "Jun",
    "Jul",
    "Aug",
    "Sep",
    "Oct",
    "Nov",
    "Dec",
  ];
  return `${date.getUTCDate()} ${months[date.getUTCMonth()]} ${date.getUTCFullYear()}`;
}

function parseArgs(argv) {
  const options = { check: false, apply: false, releaseId: "", root: "" };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--check") options.check = true;
    else if (arg === "--apply") options.apply = true;
    else if (arg === "--release-id") {
      options.releaseId = argv[index + 1] || "";
      index += 1;
    } else if (arg === "--root") {
      options.root = argv[index + 1] || "";
      index += 1;
    } else {
      throw new Error(`unknown argument: ${arg}`);
    }
  }
  return options;
}

async function run() {
  const options = parseArgs(process.argv.slice(2));
  const root = resolve(options.root || dirname(dirname(fileURLToPath(import.meta.url))));
  if (!options.check && !options.apply) {
    options.apply = true;
  }
  const catalog = await generateReleaseNotes({
    root,
    releaseId: options.releaseId,
    apply: options.apply,
    check: options.check,
  });
  process.stdout.write(
    `Release notes ${catalog.current_id}: ${catalog.releases.length} entries\n`,
  );
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  run().catch((error) => {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  });
}
