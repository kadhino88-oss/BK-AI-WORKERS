/* Constellation doree animee (pages statiques : SEO, confidentialite).
   Meme rendu que le hero de l'application. Attache un canvas a chaque
   .page-hero. Coupe si mouvement reduit / onglet ou bandeau hors ecran. */
(function () {
  if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
  function init(band) {
    var cv = document.createElement("canvas");
    cv.setAttribute("aria-hidden", "true");
    cv.style.cssText = "position:absolute;inset:0;width:100%;height:100%;pointer-events:none;z-index:0;opacity:.8";
    band.insertBefore(cv, band.firstChild);
    var inner = band.querySelector(".page-hero-in");
    if (inner) inner.style.zIndex = 1;
    var ctx = cv.getContext("2d"), dpr = Math.min(window.devicePixelRatio || 1, 2);
    var w = 0, h = 0, pts = [], running = false, visible = true, mouse = { x: -999, y: -999 };
    function resize() {
      w = band.clientWidth; h = band.clientHeight;
      cv.width = w * dpr; cv.height = h * dpr; ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      var n = Math.max(18, Math.min(60, Math.round(w * h / 18000)));
      pts = [];
      for (var i = 0; i < n; i++) pts.push({ x: Math.random() * w, y: Math.random() * h, vx: (Math.random() - .5) * .28, vy: (Math.random() - .5) * .28, r: Math.random() * 1.4 + .6 });
    }
    function frame() {
      if (!running) return;
      ctx.clearRect(0, 0, w, h);
      var i, k, p, dx, dy, d;
      for (i = 0; i < pts.length; i++) {
        p = pts[i]; p.x += p.vx; p.y += p.vy;
        if (p.x < 0 || p.x > w) p.vx *= -1;
        if (p.y < 0 || p.y > h) p.vy *= -1;
        dx = mouse.x - p.x; dy = mouse.y - p.y;
        if (dx * dx + dy * dy < 22000) { p.x -= dx * .0009; p.y -= dy * .0009; }
        ctx.beginPath(); ctx.arc(p.x, p.y, p.r, 0, 6.283); ctx.fillStyle = "rgba(226,178,84,.75)"; ctx.fill();
      }
      for (i = 0; i < pts.length; i++) for (k = i + 1; k < pts.length; k++) {
        dx = pts[i].x - pts[k].x; dy = pts[i].y - pts[k].y; d = dx * dx + dy * dy;
        if (d < 12000) {
          ctx.strokeStyle = "rgba(226,178,84," + (0.16 * (1 - d / 12000)).toFixed(3) + ")";
          ctx.lineWidth = 1; ctx.beginPath(); ctx.moveTo(pts[i].x, pts[i].y); ctx.lineTo(pts[k].x, pts[k].y); ctx.stroke();
        }
      }
      requestAnimationFrame(frame);
    }
    function sync() {
      var go = visible && !document.hidden;
      if (go && !running) { running = true; requestAnimationFrame(frame); } else if (!go) running = false;
    }
    band.addEventListener("mousemove", function (e) { var r = band.getBoundingClientRect(); mouse.x = e.clientX - r.left; mouse.y = e.clientY - r.top; });
    band.addEventListener("mouseleave", function () { mouse.x = mouse.y = -999; });
    if ("IntersectionObserver" in window) new IntersectionObserver(function (es) { visible = es[0].isIntersecting; sync(); }).observe(band);
    document.addEventListener("visibilitychange", sync);
    window.addEventListener("resize", resize);
    resize(); sync();
  }
  Array.prototype.forEach.call(document.querySelectorAll(".page-hero"), init);
})();
