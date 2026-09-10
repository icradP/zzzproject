import assert from "node:assert/strict";
import test from "node:test";

import {
  buildCatalog,
  dartString,
  humanizeSubject,
  parsePubspecVersion,
  renderDart,
  selectCommitSubjects,
} from "./generate_release_notes.mjs";

const catalog = {
  current_version: "1.6.0",
  releases: [
    {
      version: "1.6.0",
      title: "Interactive messages and ZZZ Term",
      items: ["Send live group cards."],
    },
    {
      version: "1.5.0",
      title: "Meet Fairy",
      items: ["Find Fairy in suggested contacts."],
    },
  ],
};

test("parsePubspecVersion reads the marketing version", () => {
  assert.equal(parsePubspecVersion("name: zzz\nversion: 1.6.0+1\n"), "1.6.0");
});

test("selectCommitSubjects keeps user-facing feat and fix subjects", () => {
  assert.deepEqual(
    selectCommitSubjects([
      "docs: record rollout",
      "feat(im): add generic interactive message builder",
      "test(im): make bubble golden cross-platform",
      "fix(deploy): keep native release builds local-first",
      "fix(gateway): deliver zzzterm messages to peer devices",
      "feat(im): add generic interactive message builder",
    ]),
    [
      "Add generic interactive message builder.",
      "Deliver zzzterm messages to peer devices.",
    ],
  );
});

test("buildCatalog stamps a deploy entry without dropping history", () => {
  const built = buildCatalog({
    catalog,
    pubspecVersion: "1.6.0",
    releaseId: "4cae750ecae8",
    commitSubjects: ["feat(im): complete dynamic interaction workflow"],
    date: new Date("2026-09-10T00:00:00Z"),
  });
  assert.equal(built.current_id, "1.6.0+4cae750ecae8");
  assert.equal(built.releases[0].title, "Updated 10 Sep 2026");
  assert.deepEqual(built.releases[0].items, [
    "Complete dynamic interaction workflow.",
  ]);
  assert.equal(built.releases[1].version, "1.6.0");
  assert.equal(built.releases[2].version, "1.5.0");
});

test("renderDart emits a part file with escaped strings", () => {
  const dart = renderDart(
    buildCatalog({ catalog, pubspecVersion: "1.6.0" }),
  );
  assert.match(dart, /part of 'im_release_notes.dart';/);
  assert.match(dart, /const _currentVersion = '1.6.0';/);
  assert.equal(dartString("It's $1"), "'It\\'s \\$1'");
});
