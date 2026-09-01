import { createHash } from "node:crypto";
import { readFile, readdir, stat, writeFile } from "node:fs/promises";
import { resolve, relative, sep } from "node:path";
import { pathToFileURL } from "node:url";

export const startupResources = [
  "main.dart.js",
  "canvaskit/canvaskit.js",
  "canvaskit/canvaskit.wasm",
  "canvaskit/chromium/canvaskit.js",
  "canvaskit/chromium/canvaskit.wasm",
];

async function listFiles(root, directory = root) {
  const entries = await readdir(directory, { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    const absolute = resolve(directory, entry.name);
    if (entry.isDirectory()) {
      files.push(...(await listFiles(root, absolute)));
      continue;
    }
    if (!entry.isFile()) continue;
    const path = relative(root, absolute).split(sep).join("/");
    if (path.endsWith(".gz") || path === "startup-assets.json") continue;
    files.push(path);
  }
  return files.sort();
}

export async function buildManifest(buildDirectory) {
  const root = resolve(buildDirectory);
  const files = await listFiles(root);
  const resources = {};
  let buildBytes = 0;
  for (const path of files) {
    const absolute = resolve(root, path);
    const [info, content] = await Promise.all([stat(absolute), readFile(absolute)]);
    resources[path] = {
      bytes: info.size,
      sha256: createHash("sha256").update(content).digest("hex"),
    };
    buildBytes += info.size;
  }

  const startup = {};
  for (const path of startupResources) {
    if (!Number.isFinite(resources[path]?.bytes)) {
      throw new Error(`Required Web startup resource is missing: ${path}`);
    }
    startup[path] = resources[path].bytes;
  }

  const version = createHash("sha256")
    .update(JSON.stringify(resources))
    .digest("hex")
    .slice(0, 16);
  return {
    version,
    build_bytes: buildBytes,
    resource_count: files.length,
    startup,
    resources,
  };
}

export async function writeManifest(buildDirectory) {
  const root = resolve(buildDirectory);
  const manifest = await buildManifest(root);
  await writeFile(
    resolve(root, "startup-assets.json"),
    `${JSON.stringify(manifest, null, 2)}\n`,
    "utf8",
  );
  return manifest;
}

async function main() {
  const buildDirectory = process.argv[2] || "build/web";
  const manifest = await writeManifest(buildDirectory);
  process.stdout.write(
    `Web asset manifest ${manifest.version}: ${manifest.resource_count} files, ${manifest.build_bytes} bytes\n`,
  );
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  });
}
