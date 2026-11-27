import assert from "node:assert/strict";
import { test } from "node:test";
import { activeLineAt, cleanTitle, matchLyrics, parseLrc, resolveLyrics } from "../src/lib/lyrics.ts";

const track = { id: "test-song", title: "Home", artist: "Aster", album: "Night", duration: 180, thumb: "", art: "", kind: "song" as const };
const record = { id: 1, trackName: "Home", artistName: "Aster", albumName: "Night", duration: 180, instrumental: false, plainLyrics: "One\nTwo", syncedLyrics: "[00:01]One\n[00:02]Two" };

test("LRC supports precision, repeated stamps, CRLF, offsets, empty interludes, and simultaneous voices", () => {
  assert.deepEqual(parseLrc("[ar:Aster]\r\n[offset:-500]\r\n[00:01.25][00:12.500]One\r\n[00:02.5]Two\r\n[00:03.000]\r\n[00:02.500]Other voice"), [
    { time: 0.75, text: "One" }, { time: 2, text: "Two\nOther voice" }, { time: 2.5, text: "" }, { time: 12, text: "One" },
  ]);
});

test("malformed timestamps and metadata cannot become lyrics; enhanced markers stay invisible", () => {
  assert.deepEqual(parseLrc("[ar:Aster]\n[00:99]Bad\nplain"), []);
  assert.deepEqual(parseLrc("[00:02]<00:02.0>One <00:03.00>two"), [{ time: 2, text: "One two" }]);
  assert.deepEqual(parseLrc("[00:01]\n[00:02]"), []);
});

test("the active line follows exact boundaries, backwards seeks, and instrumental gaps", () => {
  const lines = parseLrc("[00:04]One\n[00:06]\n[00:08]Two");
  assert.equal(activeLineAt(lines, 0), -1);
  assert.equal(activeLineAt(lines, 4), 0);
  assert.equal(activeLineAt(lines, 7), 1);
  assert.equal(activeLineAt(lines, 100), 2);
  assert.equal(activeLineAt(lines, 5), 0);
  assert.equal(activeLineAt([], 10), -1);
});

test("matching rejects another recording, cover artist, and alternate version", () => {
  assert.equal(matchLyrics([{ ...record, duration: 185 }], track), null);
  assert.equal(matchLyrics([{ ...record, artistName: "Other" }], track), null);
  assert.equal(matchLyrics([{ ...record, trackName: "Home (Live)" }], track), null);
  assert.equal(cleanTitle("Home (Official Audio)"), "Home");
  assert.equal(cleanTitle("Home (Acoustic)"), "Home (Acoustic)");
  assert.equal(matchLyrics([record], { ...track, title: "Home (Official Audio)", artist: "Aster - Topic" }), record);
});

test("matching prefers the correct album and synchronized data", () => {
  assert.equal(matchLyrics([{ ...record, id: 2, albumName: "Other" }, record], track)?.id, 1);
  assert.equal(matchLyrics([{ ...record, id: 2, syncedLyrics: null }, record], track)?.id, 1);
});

test("lookup falls back after no exact match without accepting a mismatched song", async () => {
  const calls: string[] = [];
  const found = await resolveLyrics(track, async (path) => {
    calls.push(path);
    return path.startsWith("/get?") ? null : [{ ...record, id: 2, duration: 210 }, record];
  });
  assert.equal(found?.id, 1);
  assert.equal(calls.length, 2);
  assert.match(calls[0], /duration=180/);
});

test("network errors do not turn into cached missing lyrics or trigger fallback calls", async () => {
  let calls = 0;
  await assert.rejects(resolveLyrics(track, async () => { calls++; throw new Error("offline"); }), /offline/);
  assert.equal(calls, 1);
});

test("instrumental and plain-only records remain usable; no metadata performs no lookup", async () => {
  const instrumental = { ...record, instrumental: true, syncedLyrics: null, plainLyrics: null };
  assert.equal(await resolveLyrics(track, async () => instrumental), instrumental);
  const plain = { ...record, syncedLyrics: null };
  assert.equal(await resolveLyrics(track, async () => plain), plain);
  assert.equal(await resolveLyrics({ ...track, artist: "" }, async () => { throw new Error("must not fetch"); }), null);
});
