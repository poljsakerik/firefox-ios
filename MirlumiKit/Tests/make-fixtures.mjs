#!/usr/bin/env node
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

// Writes the signed documents the tests check, using the mirlumi repository's packages/content-rules/lib.mjs:
//   node vendor/firefox-ios/MirlumiKit/Tests/make-fixtures.mjs   (from the mirlumi repository root)
// ECDSA signatures are randomized, so rerunning changes every file; that's expected.
import { generateKeyPairSync, sign } from "node:crypto";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const lib = await import(join(here, "../../../../packages/content-rules/lib.mjs"));
const out = join(here, "MirlumiKitTests/Fixtures");
mkdirSync(out, { recursive: true });

const bundled = JSON.parse(lib.bundledRulesText());
const withVersion = (version) => JSON.stringify({ ...bundled, version });
const write = (name, signed) => writeFileSync(join(out, name), `${JSON.stringify(signed, null, 2)}\n`);
// Signs bytes as they are, without validating them, for documents the apps must refuse.
const signRaw = (payload, key) => ({
  payload: payload.toString("base64"),
  signature: sign("sha256", payload, { key, dsaEncoding: "ieee-p1363" }).toString("base64"),
});

const debug = lib.debugPrivateKey();
writeFileSync(join(out, "debug.pem"), lib.debugPublicKey());
write("next-version.json", lib.signRules(withVersion(bundled.version + 1), debug));
write("same-version.json", lib.signRules(withVersion(bundled.version), debug));
write("other-key.json", lib.signRules(withVersion(bundled.version + 1), generateKeyPairSync("ec", { namedCurve: "P-256" }).privateKey.export({ type: "pkcs8", format: "pem" })));
write("byte-order-mark.json", signRaw(Buffer.concat([Buffer.from([0xef, 0xbb, 0xbf]), Buffer.from(withVersion(bundled.version + 1))]), debug));
const invalid = { ...bundled, version: bundled.version + 1, sites: { instagram: [{ hosts: ["instagram.com"], blockPaths: ["^/reels"], redirect: "//evil.example/" }] } };
write("invalid-rules.json", signRaw(Buffer.from(JSON.stringify(invalid)), debug));
console.log(`Wrote fixtures for rules version ${bundled.version}.`);
