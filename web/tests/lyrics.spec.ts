import { test, expect, type Page } from "@playwright/test";

const art = "data:image/svg+xml," + encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" width="400" height="400"><defs><linearGradient id="g" x2="1" y2="1"><stop stop-color="#c67948"/><stop offset=".5" stop-color="#75416e"/><stop offset="1" stop-color="#183653"/></linearGradient></defs><path fill="url(#g)" d="M0 0h400v400H0z"/><circle cx="270" cy="110" r="70" fill="#f4c790" opacity=".6"/><path d="M0 280Q80 190 160 270T400 220V400H0" fill="#252a43"/></svg>');
const track = { id: "lyrics-test", title: "After the Rain", artist: "The Midnight Letters", album: "Somewhere Quiet", duration: 60, thumb: art, art, kind: "song" };
const phrases = ["Under a midnight sky", "We let the city fade", "And all the words we kept", "Come falling with the rain", "There is a light ahead", "Beyond the empty streets", "I hear the morning call", "And find my way to you"];
const record = { id: 1, trackName: track.title, artistName: track.artist, albumName: track.album, duration: 60, instrumental: false, plainLyrics: phrases.join("\n"), syncedLyrics: phrases.map((s, i) => `[00:${String(4 + i * 4).padStart(2, "0")}.00] ${s}`).join("\n") };

async function setup(page: Page, response: unknown = record, status = 200) {
  await page.addInitScript((track) => {
    localStorage.setItem("musike:player", JSON.stringify({ queue: [track], index: 0, position: 8, autoRadio: false }));
  }, track);
  await page.route("**/api/**", async (route) => {
    const url = route.request().url();
    if (url.startsWith("https://lrclib.net/")) {
      return route.fulfill({ status, json: response, headers: { "Retry-After": "60" } });
    }
    if (url.includes("/library")) return route.fulfill({ json: { favorites: [], history: [], playlists: [] } });
    if (url.includes("/system")) return route.fulfill({ json: { ytdlp: { path: "/test", latest: {}, updateAvailable: false } } });
    return route.fulfill({ json: { genres: [], tracks: [] } });
  });
  await page.goto("/#now-playing");
  await page.getByRole("button", { name: "Show lyrics", exact: true }).click();
  if (page.viewportSize()!.width < 768) await expect(page.getByRole("dialog")).toHaveCSS("opacity", "1");
}

async function playerState(page: Page, state: Record<string, unknown>) {
  await page.evaluate(async (state) => {
    const { usePlayer } = await import(/* @vite-ignore */ "/src/player/player.ts");
    usePlayer.setState(state);
  }, state);
}

test("phone: active lines, tap-to-seek, browsing, timing and controls", async ({ page }, info) => {
  await setup(page);
  const view = page.getByRole("region", { name: "Lyrics", exact: true });
  await expect(view.locator('[aria-current="true"]')).toContainText(phrases[1]);
  await view.locator('[data-line="3"]').click();
  await expect(view.locator('[aria-current="true"]')).toContainText(phrases[3]);
  await expect(page.getByRole("dialog").getByRole("slider", { name: "Progress" })).toHaveAttribute("aria-valuenow", "16");
  await playerState(page, { position: 8 });
  await expect(view.locator('[aria-current="true"]')).toContainText(phrases[1]);
  await page.mouse.move(2, 2);
  await page.screenshot({ path: info.outputPath("lyrics-phone.png") });
  await view.locator(".lyrics-scroll").hover();
  await page.mouse.wheel(0, 150);
  await expect(view.getByRole("button", { name: "Back to current line" })).toBeVisible();
  await view.getByRole("button", { name: "Back to current line" }).click();
  await expect(view).toHaveAttribute("data-following", "true");
  await view.getByRole("button", { name: "Adjust timing" }).click();
  await view.getByRole("button", { name: "Show lyrics half a second later" }).click();
  await expect(view.locator('[aria-current="true"]')).toContainText(phrases[0]);
  await view.getByRole("button", { name: "Reset", exact: true }).click();
  await expect(view.locator('[aria-current="true"]')).toContainText(phrases[1]);
  await page.getByRole("button", { name: "Hide lyrics" }).click();
  await expect(page.getByRole("button", { name: "Show lyrics", exact: true })).toBeVisible();
});

test("plain lyrics do not expose fake timing or seek buttons", async ({ page }) => {
  await setup(page, { ...record, syncedLyrics: null });
  await expect(page.getByText("Full lyrics · timing unavailable")).toBeVisible();
  await expect(page.locator(".lyrics-plain")).toContainText(phrases[0]);
  await expect(page.locator(".lyric-line")).toHaveCount(0);
});

test("instrumental tracks leave playback controls accessible", async ({ page }) => {
  await setup(page, { ...record, instrumental: true, plainLyrics: null, syncedLyrics: null });
  await expect(page.getByText("Just the music", { exact: true })).toBeVisible();
  await expect(page.getByRole("dialog").getByRole("button", { name: "Play", exact: true })).toBeVisible();
});

test("no match displays a clear empty state", async ({ page }) => {
  await setup(page, []);
  await expect(page.getByText("No lyrics just yet", { exact: true })).toBeVisible();
});

test("rate limiting does not send another request on retry", async ({ page }) => {
  let requests = 0;
  page.on("request", (r) => { if (r.url().startsWith("https://lrclib.net/")) requests++; });
  await setup(page, {}, 429);
  await expect(page.getByText(/lyrics service is busy/)).toBeVisible();
  await page.getByRole("button", { name: "Try again" }).click();
  await expect(page.getByText(/lyrics service is busy/)).toBeVisible();
  expect(requests).toBe(1);
});

test("failed lookups can be retried, successful ones survive offline reopening", async ({ page }) => {
  await setup(page, {}, 500);
  await expect(page.getByText("Lyrics couldn’t load", { exact: true })).toBeVisible();
  await page.route("https://lrclib.net/**", (route) => route.fulfill({ json: record }));
  await page.getByRole("button", { name: "Try again" }).click();
  await expect(page.locator('[aria-current="true"]')).toContainText(phrases[1]);
  await page.route("https://lrclib.net/**", (route) => route.abort());
  await page.reload();
  await page.getByRole("button", { name: "Show lyrics", exact: true }).click();
  await expect(page.locator('[aria-current="true"]')).toContainText(phrases[1]);
});

test("track changes clear old lyrics and ignore late responses", async ({ page }) => {
  await setup(page);
  await expect(page.locator('[aria-current="true"]')).toContainText(phrases[1]);
  await page.route("https://lrclib.net/**", async (route) => {
    await new Promise((resolve) => setTimeout(resolve, 500));
    await route.fulfill({ json: [] });
  });
  await playerState(page, { queue: [{ ...track, id: "new-song", title: "Another song" }], position: 0 });
  await expect(page.getByText("Finding the words…", { exact: true })).toBeVisible();
  await expect(page.locator(".lyric-line")).toHaveCount(0);
  await playerState(page, { queue: [track], position: 12 });
  await expect(page.locator('[aria-current="true"]')).toContainText(phrases[2]);
});

test("video playback falls back to readable lyrics without false synchronization", async ({ page }) => {
  await setup(page);
  await expect(page.locator('[aria-current="true"]')).toContainText(phrases[1]);
  await playerState(page, { mediaKind: "video" });
  await expect(page.getByText("Full lyrics · video timing may differ")).toBeVisible();
  await expect(page.locator(".lyric-line")).toHaveCount(0);
});

test("small phone and light theme keep lyrics and controls inside the viewport", async ({ page }, info) => {
  await page.setViewportSize({ width: 320, height: 568 });
  await setup(page);
  await page.evaluate(() => { document.documentElement.dataset.theme = "light"; });
  await expect(page.locator('[aria-current="true"]')).toContainText(phrases[1]);
  const button = await page.getByRole("button", { name: "Hide lyrics" }).boundingBox();
  expect(button!.y + button!.height).toBeLessThanOrEqual(568);
  expect(await page.locator(".lyrics-scroll").evaluate((el) => el.clientHeight)).toBeGreaterThan(100);
  expect(await page.locator(".lyrics-view").evaluate((el) => getComputedStyle(el).color)).toBe("rgb(255, 255, 255)");
  await page.screenshot({ path: info.outputPath("lyrics-small-phone.png") });
});

test("desktop lyrics panel opens from the player bar", async ({ page }, info) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  await setup(page);
  await expect(page.locator(".lyrics-panel")).toBeVisible();
  await expect(page.locator('[aria-current="true"]')).toContainText(phrases[1]);
  await page.screenshot({ path: info.outputPath("lyrics-desktop.png") });
});

test("lyrics follow real media time updates, pause, and seeking", async ({ page }) => {
  await setup(page);
  // A real, silent PCM WAV exercises the HTML audio player without external streams.
  const samples = 8000 * 60;
  const wav = Buffer.alloc(44 + samples * 2);
  wav.write("RIFF", 0); wav.writeUInt32LE(wav.length - 8, 4); wav.write("WAVEfmt ", 8);
  wav.writeUInt32LE(16, 16); wav.writeUInt16LE(1, 20); wav.writeUInt16LE(1, 22);
  wav.writeUInt32LE(8000, 24); wav.writeUInt32LE(16000, 28); wav.writeUInt16LE(2, 32);
  wav.writeUInt16LE(16, 34); wav.write("data", 36); wav.writeUInt32LE(samples * 2, 40);
  await page.route("**/api/stream/**", (route) => {
    const range = route.request().headers().range?.match(/bytes=(\d+)-(\d*)/);
    if (!range) return route.fulfill({ contentType: "audio/wav", body: wav, headers: { "Accept-Ranges": "bytes" } });
    const start = Number(range[1]);
    const end = range[2] ? Math.min(Number(range[2]), wav.length - 1) : wav.length - 1;
    return route.fulfill({ status: 206, contentType: "audio/wav", body: wav.subarray(start, end + 1), headers: {
      "Accept-Ranges": "bytes", "Content-Range": `bytes ${start}-${end}/${wav.length}`,
    } });
  });
  const sheet = page.getByRole("dialog");
  await sheet.getByRole("button", { name: "Play", exact: true }).click();
  await expect(sheet.getByRole("button", { name: "Pause", exact: true })).toBeVisible();
  await expect.poll(async () => Number(await sheet.getByRole("slider", { name: "Progress" }).getAttribute("aria-valuenow"))).toBeGreaterThan(9);
  await page.locator('[data-line="4"]').click();
  await expect(page.locator('[aria-current="true"]')).toContainText(phrases[4]);
  await expect.poll(async () => Number(await sheet.getByRole("slider", { name: "Progress" }).getAttribute("aria-valuenow"))).toBeGreaterThan(20.5);
  await sheet.getByRole("button", { name: "Pause", exact: true }).click();
  await page.locator('[data-line="1"]').click();
  await expect(page.locator('[aria-current="true"]')).toContainText(phrases[1]);
  await expect(sheet.getByRole("button", { name: "Play", exact: true })).toBeVisible();
});
