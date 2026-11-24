/* Live Home + Genres for the original Musike bundle. No random data. */
(function () {
  "use strict";

  var HOME_ID = "musike-live-home";
  var GENRE_ID = "musike-live-genres";
  var SNAPSHOT = "/assets/apple-charts.json";
  var FEED = "https://rss.marketingtools.apple.com/api/v2/gh/music/most-played/100/songs.json";
  var CACHE = "musike:apple-charts-v3";
  var results = [];
  var requested = false;

  function seed(data) {
    var items = data && data.feed && data.feed.results;
    if (!Array.isArray(items) || !items.length) return;
    results = items;
    try { localStorage.setItem(CACHE, JSON.stringify({ at: Date.now(), items: items })); } catch (e) {}
    render();
  }

  function load() {
    if (requested) return;
    requested = true;
    try {
      var saved = JSON.parse(localStorage.getItem(CACHE) || "null");
      if (saved && Array.isArray(saved.items) && saved.items.length) {
        results = saved.items;
        render();
      }
    } catch (e) {}

    // Same-origin bundled snapshot guarantees Home works offline / without CORS.
    fetch(SNAPSHOT).then(function (r) { return r.json(); }).then(seed).catch(function () {});

    // Attempt a true live refresh cross-origin; keep snapshot if blocked.
    fetch(FEED).then(function (r) {
      if (!r.ok) throw Error("HTTP " + r.status);
      return r.json();
    }).then(seed).catch(function () {});
  }

  function listeningScores() {
    var scores = Object.create(null);
    try {
      var events = JSON.parse(localStorage.getItem("musike:listening-events") || "[]");
      for (var i = 0; i < events.length; i++) {
        var e = events[i] || {};
        var artist = String(e.artist || "").split(",")[0].trim().toLowerCase();
        if (!artist) continue;
        var w = 1;
        if (e.type === "track_favorited") w = 5;
        else if (e.type === "track_replayed") w = 3;
        else if (e.type === "track_completed") w = 2;
        else if (e.type === "track_skipped") w = -1;
        scores[artist] = (scores[artist] || 0) + w;
      }
    } catch (e) {}
    return scores;
  }

  function navigate(query, type) {
    var q = encodeURIComponent(query);
    var url = "/search?q=" + q + (type ? "&type=" + type : "");
    history.pushState({}, "", url);
    window.dispatchEvent(new PopStateEvent("popstate"));
  }

  function section(title, items) {
    var wrap = document.createElement("section");
    wrap.className = "am-live-section";
    var h = document.createElement("h2");
    h.className = "am-live-heading";
    h.textContent = title;
    wrap.appendChild(h);

    var list = document.createElement("ul");
    list.className = "am-live-shelf";
    for (var i = 0; i < items.length; i++) {
      var item = items[i];
      var li = document.createElement("li");
      var b = document.createElement("button");
      b.type = "button";
      b.className = "am-live-card";
      b.setAttribute("aria-label", "Search for " + (item.name || "") + " by " + (item.artistName || ""));
      var img = document.createElement("img");
      if (item.artworkUrl100) img.src = String(item.artworkUrl100).replace(/100x100bb/, "400x400bb");
      img.alt = "";
      img.loading = "lazy";
      var name = document.createElement("span");
      name.className = "am-live-title";
      name.textContent = item.name || "";
      var artist = document.createElement("span");
      artist.className = "am-live-artist";
      artist.textContent = item.artistName || "";
      b.appendChild(img); b.appendChild(name); b.appendChild(artist);
      b.addEventListener("click", (function (n, a) {
        return function () { navigate((n + " " + a).trim(), "song"); };
      })(item.name || "", item.artistName || ""));
      li.appendChild(b);
      list.appendChild(li);
    }
    wrap.appendChild(list);
    return wrap;
  }

  function renderGenres() {
    var old = document.getElementById(GENRE_ID);
    var genreStamp = results.length + ":" + location.pathname;
    if (old && old.dataset.stamp === genreStamp) return;
    if (old) old.remove();
    if (location.pathname.indexOf("/search") !== 0 || !results.length) return;
    var counts = Object.create(null);
    for (var i = 0; i < results.length; i++) {
      var genres = (results[i] && results[i].genres) || [];
      for (var j = 0; j < genres.length; j++) {
        var g = genres[j] && genres[j].name;
        if (g) counts[g] = (counts[g] || 0) + 1;
      }
    }
    var names = Object.keys(counts).sort(function (a, b) { return counts[b] - counts[a]; }).slice(0, 14);
    var form = document.querySelector('main form[role="search"]');
    if (!names.length || !form || !form.parentNode) return;
    var row = document.createElement("div");
    row.id = GENRE_ID;
    row.className = "am-live-genres";
    row.dataset.stamp = genreStamp;
    for (var k = 0; k < names.length; k++) {
      var chip = document.createElement("button");
      chip.type = "button";
      chip.className = "am-live-genre";
      chip.textContent = names[k];
      chip.addEventListener("click", (function (name) {
        return function () { navigate(name, "song"); };
      })(names[k]));
      row.appendChild(chip);
    }
    form.parentNode.insertBefore(row, form.nextSibling);
  }

  function render() {
    var main = document.querySelector("main");
    var home = location.pathname === "/";
    if (!main) return;

    var stamp = location.pathname + ":" + results.length;
    var old = document.getElementById(HOME_ID);
    renderGenres();
    if (!home || !results.length) {
      if (old) old.remove();
      return;
    }
    var hasTarget = !!main.querySelector('div.pb-8 > div.glass-thin');
    var correctlyPlaced = old && old.parentElement &&
      (old.parentElement.classList.contains('pb-8') || !hasTarget);
    if (old && old.dataset.stamp === stamp && correctlyPlaced) return;
    if (old) old.remove();

    var scores = listeningScores();
    var recommended = results.filter(function (item) {
      var a = String(item.artistName || "").split(",")[0].trim().toLowerCase();
      return a && scores[a] > 0;
    }).sort(function (a, b) {
      var aa = String(a.artistName || "").split(",")[0].trim().toLowerCase();
      var bb = String(b.artistName || "").split(",")[0].trim().toLowerCase();
      return (scores[bb] || 0) - (scores[aa] || 0);
    }).slice(0, 20);
    if (!recommended.length) recommended = results.slice(0, 20);

    var newer = results.slice().sort(function (a, b) {
      return String(b.releaseDate || "").localeCompare(String(a.releaseDate || ""));
    }).slice(0, 20);

    var root = document.createElement("div");
    root.id = HOME_ID;
    root.className = "am-live-home";
    root.dataset.stamp = stamp;
    root.appendChild(section("Made for You", recommended));
    root.appendChild(section("New Releases", newer));
    root.appendChild(section("Top Charts", results.slice(0, 30)));
    var target = main.querySelector('div.pb-8 > div.glass-thin') ||
                 main.querySelector('div.glass-thin[class*="rounded-[20px]"]');
    if (target) target.replaceWith(root); else main.appendChild(root);
  }

  function schedule() {
    if (location.pathname === "/" || location.pathname.indexOf("/search") === 0) load();
    render();
  }

  var push = history.pushState;
  history.pushState = function () { var r = push.apply(this, arguments); schedule(); return r; };
  window.addEventListener("popstate", schedule);
  document.addEventListener("DOMContentLoaded", schedule);
  if (document.readyState !== "loading") schedule();
  var queued = false;
  new MutationObserver(function () {
    if (queued) return;
    queued = true;
    queueMicrotask(function () { queued = false; schedule(); });
  }).observe(document.documentElement, { childList: true, subtree: true });
})();
