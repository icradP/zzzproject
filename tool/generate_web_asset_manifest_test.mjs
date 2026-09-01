import assert from "node:assert/strict";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import test from "node:test";

import {
  buildManifest,
  startupResources,
  writeManifest,
} from "./generate_web_asset_manifest.mjs";

async function fixture() {
  const directory = await mkdtemp(join(tmpdir(), "zzz-web-manifest-"));
  for (const [index, path] of startupResources.entries()) {
    const target = join(directory, path);
    await mkdir(dirname(target), { recursive: true });
    await writeFile(target, Buffer.alloc(index + 2));
  }
  await writeFile(join(directory, "ignored.js.gz"), Buffer.alloc(100));
  return directory;
}

test("buildManifest reports deterministic startup and build sizes", async () => {
  const directory = await fixture();
  try {
    const first = await buildManifest(directory);
    const second = await buildManifest(directory);
    assert.deepEqual(first, second);
    assert.equal(first.resource_count, startupResources.length);
    assert.equal(first.build_bytes, 2 + 3 + 4 + 5 + 6);
    assert.equal(first.startup["main.dart.js"], 2);
    assert.equal(first.resources["main.dart.js"].bytes, 2);
    assert.match(first.resources["main.dart.js"].sha256, /^[a-f0-9]{64}$/);
    assert.match(first.version, /^[a-f0-9]{16}$/);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("writeManifest creates the browser startup manifest", async () => {
  const directory = await fixture();
  try {
    const expected = await writeManifest(directory);
    const saved = JSON.parse(
      await readFile(join(directory, "startup-assets.json"), "utf8"),
    );
    assert.deepEqual(saved, expected);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("buildManifest rejects incomplete Web builds", async () => {
  const directory = await mkdtemp(join(tmpdir(), "zzz-web-manifest-"));
  try {
    await assert.rejects(
      buildManifest(directory),
      /Required Web startup resource is missing/,
    );
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
