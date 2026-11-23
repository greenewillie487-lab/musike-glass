/* apple-music-live.js — live Home shelves from Apple's public chart feed.
   No random data. Recommendations come from the app's real listening history. */
(function () {
  "use strict";

  var FEED_ROOT = "https://rss.marketingtools.apple.com/api/v2/";
  var CACHE_KEY = "musike:live-charts-v1";
  var WRAPPER_ID = "musike-live-home";
  var store = "us";

  try {
    var lang = (navigator.language || "en-US").toLowerCase();
    if (lang.indexOf("gh") >= 0 || lang.indexOf("en-gh") >= 0) store = "gh";
  } catch (e) {}

  function feedURL() {
    return FEED_ROOT + store + "/music/most-played/100/songs.json";
  }

  function listeningEvents() {
    try { return JSON.parse(localStorage.getItem("musike:listening-events") || "[]"); }
    catch (e) { return []; }
  }

  function artistScores() {
    var scores = Object.create(null);
    var events = listeningEvents();
    for (var i = 0; i < events.length; i++) {
      var e = events[i] || {};
      var name = String(e.artist || "").split(",")[0].trim().toLowerCase();
      if (!name) continue;
      var weight = 1;
      if (e.type === "track_favorited") weight = 5;
      else if (e.type === "track_replayed") weight = 3;
      else if (e.type === "track_completed") weight = 2;
      else if (e.type === "track_skipped") weight = -1;
      if (typeof e.completion === "number") weight *= Math.max(0.1, e.completion);
      scores[name] = (scores[name] || 0) + weight;
    }
    return scores;
  }

  function cachedFeed() {
    try {
      var raw = localStorage.getItem(CACHE_KEY);
      if (!raw) return null;
      var parsed = JSON.parse(raw);
      if (Date.now() - parsed.at > 15 * 60 * 1000) return null;
      return parsed.data;
    } catch (e) { return null; }
  }

  function loadFeed(force) {
    var cached = cachedFeed();
    if (!force && cached) { render(cached.results || []); return; }

    var id = "live-" + Date.now();
    window.__musikeLiveResult = function (resultId, json) {
      if (resultId !== id) return;
      try {
        var data = JSON.parse(json);
        localStorage.setItem(CACHE_KEY, JSON.stringify({ at: Date.now(), data: data }));
        render((data.feed && data.feed.results) || []);
      } catch (e) {}
    };

    var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.musikeLive;
    if (handler) {
      handler.postMessage({ id: id, url: feedURL() });
    } else if (window.fetch) {
      fetch(feedURL()).then(function (r) { return r.json(); }).then(function (data) {
        window.__musikeLiveResult(id, JSON.stringify(data));
      }).catch(function () {});
    }
  }

  function section(title, items) {
    var wrap = document.createElement("section");
    wrap.className = "am-live-section";
    var heading = document.createElement("h2");
    heading.className = "am-live-heading";
    heading.textContent = title;
    wrap.appendChild(heading);

    var list = document.createElement("ul");
    list.className = "am-live-shelf";
    for (var i = 0; i < items.length; i++) {
      var item = items[i];
      var li = document.createElement("li");
      var button = document.createElement("button");
      button.type = "button";
      button.className = "am-live-card";
      button.setAttribute("aria-label", "Search for " + item.name + " by " + item.artistName);

      var img = document.createElement("img");
      img.src = String(item.artworkUrl100 || "").replace(/100x100bb/, "400x400bb");
      img.alt = "";
      img.loading = "lazy";

      var name = document.createElement("span");
      name.className = "am-live-title";
      name.textContent = item.name || "";
      var artist = document.createElement("span");
      artist.className = "am-live-artist";
      artist.textContent = item.artistName || "";

      button.appendChild(img);
      button.appendChild(name);
      button.appendChild(artist);
      button.addEventListener("click", (function (n, a) {
        return function () {
          var q = encodeURIComponent(n + " " + a);
          history.pushState({}, "", "/search?q=" + q);
          window.dispatchEvent(new PopStateEvent("popstate"));
        };
      })(item.name || "", item.artistName || ""));

      li.appendChild(button);
      list.appendChild(li);
    }
    wrap.appendChild(list);
    return wrap;
  }

  function renderGenres(results) {
    var existing = document.getElementById("musike-live-genres");
    if (existing) existing.remove();
    var counts = Object.create(null);
    for (var i = 0; i < results.length; i++) {
      var genres = (results[i] && results[i].genres) || [];
      for (var j = 0; j < genres.length; j++) {
        var g = genres[j] && genres[j].name;
        if (g) counts[g] = (counts[g] || 0) + 1;
      }
    }
    var names = Object.keys(counts).sort(function (a, b) { return counts[b] - counts[a]; }).slice(0, 14);
    if (!names.length) return;
    var form = document.querySelector('main form[role="search"]');
    if (!form || !form.parentNode) return;
    var row = document.createElement("div");
    row.id = "musike-live-genres";
    row.className = "am-live-genres";
    for (var k = 0; k < names.length; k++) {
      var chip = document.createElement("button");
      chip.type = "button";
      chip.className = "am-live-genre";
      chip.textContent = names[k];
      chip.addEventListener("click", (function (name) {
        return function () {
          history.pushState({}, "", "/search?q=" + encodeURIComponent(name) + "&type=song");
          window.dispatchEvent(new PopStateEvent("popstate"));
        };
      })(names[k]));
      row.appendChild(chip);
    }
    form.parentNode.insertBefore(row, form.nextSibling);
  }

  function render(results) {
    if (location.pathname === "/search") { renderGenres(results); return; }
    if (location.pathname !== "/" || !results.length) return;
    var main = document.querySelector("main");
    if (!main) return;

    var old = document.getElementById(WRAPPER_ID);
    if (old) old.remove();

    var root = document.createElement("div");
    root.id = WRAPPER_ID;
    root.className = "am-live-home";

    var scores = artistScores();
    var recommended = results.filter(function (item) {
      var artist = String(item.artistName || "").split(",")[0].trim().toLowerCase();
      return artist && scores[artist] > 0;
    }).sort(function (a, b) {
      var aa = String(a.artistName || "").split(",")[0].trim().toLowerCase();
      var bb = String(b.artistName || "").split(",")[0].trim().toLowerCase();
      return (scores[bb] || 0) - (scores[aa] || 0);
    }).slice(0, 20);
    if (!recommended.length) recommended = results.slice(0, 20);

    var newer = results.slice().sort(function (a, b) {
      return String(b.releaseDate || "").localeCompare(String(a.releaseDate || ""));
    }).slice(0, 20);

    root.appendChild(section("Made for You", recommended));
    root.appendChild(section("New Releases", newer));
    root.appendChild(section("Top Charts", results.slice(0, 30)));
    main.appendChild(root);
  }

  function ensure() {
    var onHome = location.pathname === "/";
    var onSearch = location.pathname.indexOf("/search") === 0;
    if (!onHome && !onSearch) {
      var old = document.getElementById(WRAPPER_ID);
      if (old) old.remove();
      var genres = document.getElementById("musike-live-genres");
      if (genres) genres.remove();
      return;
    }
    if (onHome && !document.getElementById(WRAPPER_ID)) loadFeed(false);
    else if (onSearch) loadFeed(false);
  }

  var push = history.pushState;
  history.pushState = function () { var r = push.apply(this, arguments); ensure(); return r; };
  var replace = history.replaceState;
  history.replaceState = function () { var r = replace.apply(this, arguments); ensure(); return r; };
  window.addEventListener("popstate", ensure);
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", ensure);
  else ensure();
})();
