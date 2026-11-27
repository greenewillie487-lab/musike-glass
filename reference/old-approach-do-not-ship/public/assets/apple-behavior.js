/* Small UI defaults requested by the user. Does not touch playback, lyrics,
   queue or library data — it only selects the Genres filter on Search results. */
(function () {
  var KEY = "musike-skin-genres-tab";

  function isSelected(el) {
    if (el.getAttribute("aria-selected") === "true") return true;
    if (el.getAttribute("aria-pressed") === "true") return true;
    return /bg-(surface-[1-4]|accent)|text-fg(?!-2)/.test(el.className);
  }

  function selectGenres() {
    if (location.pathname !== "/search") {
      try { sessionStorage.removeItem(KEY); } catch (e) {}
      return;
    }
    try { if (sessionStorage.getItem(KEY)) return; } catch (e) {}

    var candidates = document.querySelectorAll("main button, main [role='tab']");
    for (var i = 0; i < candidates.length; i++) {
      var el = candidates[i];
      if (el.textContent.trim() !== "Genres") continue;
      var parent = el.parentElement;
      if (!parent) continue;
      var siblings = parent.textContent;
      // Idle "browse genres" chip: mark it as the default selection.
      if (!/Songs/.test(siblings) && !/Videos/.test(siblings) && !/Albums/.test(siblings)) {
        el.classList.add("am-genres-on");
        continue;
      }
      if (isSelected(el)) {
        try { sessionStorage.setItem(KEY, "1"); } catch (e) {}
        return;
      }
      try { sessionStorage.setItem(KEY, "1"); } catch (e) {}
      el.click();
      return;
    }
  }

  document.addEventListener(
    "input",
    function (e) {
      if (e.target && e.target.tagName === "INPUT") {
        try { sessionStorage.removeItem(KEY); } catch (err) {}
      }
    },
    true
  );

  var q1 = false;
  function scheduleGenres() { if (q1) return; q1 = true; requestAnimationFrame(function () { q1 = false; selectGenres(); }); }
  new MutationObserver(scheduleGenres).observe(document.documentElement, { childList: true, subtree: true });
  window.addEventListener("popstate", selectGenres);
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", selectGenres);
  else selectGenres();

  /* Match the reference bottom bars: a Radio tab wired to Autoplay radio,
     and a "Not Playing" bar when no track is loaded. */
  var radioSel = "[data-am-radio]";
  var idleSel = ".am-mini-idle";
  var realMini = 'div[class*="bottom-[calc(84px"]';

  function autoRadioOn() {
    try {
      var raw = JSON.parse(localStorage.getItem("musike:player") || "{}");
      return raw.autoRadio !== false;
    } catch (e) { return true; }
  }

  function buildRadio() {
    var ul = document.querySelector('nav.fixed[aria-label="Main navigation"] ul');
    if (!ul) return;
    var links = ul.querySelectorAll("a");
    for (var j = 0; j < links.length; j++) {
      links[j].classList.remove("am-active");
    }
    if (document.querySelector(radioSel)) return;
    var b = document.createElement("button");
    b.setAttribute("data-am-radio", "1");
    b.setAttribute("type", "button");
    b.setAttribute("title", "Autoplay radio");
    b.style.order = "2";
    b.innerHTML =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round">' +
      '<path d="M12 13.8a1.9 1.9 0 1 0 0-3.8 1.9 1.9 0 0 0 0 3.8ZM7.7 16.3a6.1 6.1 0 0 1 0-8.6M16.3 7.7a6.1 6.1 0 0 1 0 8.6M4.8 19.2a10.2 10.2 0 0 1 0-14.4M19.2 4.8a10.2 10.2 0 0 1 0 14.4"/></svg><span>Radio</span>';
    b.onclick = function () {
      var raw = {};
      try { raw = JSON.parse(localStorage.getItem("musike:player") || "{}"); } catch (e) {}
      raw.autoRadio = !autoRadioOn();
      try { localStorage.setItem("musike:player", JSON.stringify(raw)); } catch (e) {}
      b.classList.toggle("am-radio-on", raw.autoRadio);
    };
    ul.appendChild(b);
  }

  function buildIdlePlayer() {
    var real = document.querySelector(realMini) || document.querySelector('button[aria-label="Pause"]')?.closest('div.fixed');
    var idle = document.querySelector(idleSel);
    if (real) {
      real.classList.add('am-mini-real');
      if (idle) idle.remove();
      return;
    }
    if (idle) return;
    var d = document.createElement("div");
    d.className = "am-mini-idle";
    d.innerHTML =
      '<div class="am-left"><span class="am-note"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M10 17.6V5.9l10-2.2v11.8M10 17.6a2.4 2.4 0 1 1-2.4-2.4c.8 0 1.5.4 1.9 1M20 15.5a2.4 2.4 0 1 1-2.4-2.4c.8 0 1.5.4 1.9 1"/></svg></span><span>Not Playing</span></div>' +
      '<div class="am-controls"><svg viewBox="0 0 24 24" fill="currentColor"><path d="M7.6 5.1a1.1 1.1 0 0 1 1.7-.9l10.2 6.9a1.1 1.1 0 0 1 0 1.8L9.3 19.8a1.1 1.1 0 0 1-1.7-.9z"/></svg>' +
      '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M6.1 5.2 15.8 11.3a.9.9 0 0 1 0 1.5l-9.7 6.1a.9.9 0 0 1-1.4-.8V6a.9.9 0 0 1 1.4-.8zM16.8 5.2h2.5v13.6h-2.5z"/></svg></div>';
    document.body.appendChild(d);
  }


  function styleTabIcons() {
    var ul = document.querySelector('nav.fixed[aria-label="Main navigation"] ul');
    if (!ul) return;
    var kids = ul.children;
    for (var i = 0; i < kids.length; i++) {
      var a = kids[i].querySelector('a,button') || kids[i];
      var svg = a.querySelector('svg');
      var path = svg ? svg.querySelector('path') : null;
      if (!path) continue;
      var href = a.getAttribute('href') || '';
      svg.setAttribute('viewBox', '0 0 24 24');
      if (href === '/') {
        svg.setAttribute('fill', 'currentColor');
        svg.setAttribute('stroke', 'none');
        path.setAttribute('d', 'M11.2 2.7a1.3 1.3 0 0 1 1.6 0l8.2 6.8c.3.3.5.7.5 1.1V20a1.6 1.6 0 0 1-1.6 1.6h-5.4v-6.6H9.5v6.6H4.1A1.6 1.6 0 0 1 2.5 20v-9.4c0-.4.2-.8.5-1.1z');
      } else if (href === '/library') {
        svg.setAttribute('fill', 'none');
        svg.setAttribute('stroke', 'currentColor');
        svg.setAttribute('stroke-width', '1.8');
        svg.setAttribute('stroke-linecap', 'round');
        svg.setAttribute('stroke-linejoin', 'round');
        path.setAttribute('d', 'M10 17.5V5.8l9-2v11.6M10 17.5a2.3 2.3 0 1 1-2.3-2.3c.7 0 1.3.3 1.7.9M19 15.4a2.3 2.3 0 1 1-2.3-2.3c.7 0 1.3.3 1.7.9');
      } else if (a.getAttribute('data-am-radio')) {
        svg.setAttribute('fill', 'none');
        svg.setAttribute('stroke', 'currentColor');
        svg.setAttribute('stroke-width', '2');
        svg.setAttribute('stroke-linecap', 'round');
        path.setAttribute('d', 'M12 13.8a1.9 1.9 0 1 0 0-3.8 1.9 1.9 0 0 0 0 3.8ZM7.7 16.3a6.1 6.1 0 0 1 0-8.6M16.3 7.7a6.1 6.1 0 0 1 0 8.6M4.8 19.2a10.2 10.2 0 0 1 0-14.4M19.2 4.8a10.2 10.2 0 0 1 0 14.4');
      } else if (href === '/search') {
        svg.setAttribute('fill', 'none');
        svg.setAttribute('stroke', 'currentColor');
        svg.setAttribute('stroke-width', '1.8');
        svg.setAttribute('stroke-linecap', 'round');
        path.setAttribute('d', 'M10.7 4a6.7 6.7 0 1 1 0 13.4 6.7 6.7 0 0 1 0-13.4ZM15.6 15.6 20.5 20.5');
      }
    }
  }

  function buildBars() { buildRadio(); buildIdlePlayer(); styleTabIcons(); }
  var q2 = false;
  function scheduleBars() { if (q2) return; q2 = true; requestAnimationFrame(function () { q2 = false; buildBars(); }); }
  new MutationObserver(scheduleBars).observe(document.documentElement, { childList: true, subtree: true });
  window.addEventListener("popstate", buildBars);
  document.addEventListener("click", scheduleBars, true);
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", buildBars);
  else buildBars();
})();
