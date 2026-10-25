// Marquee for one-line text too long for its box. Shared by the main window
// (the status bar and both Now Playing lines, via renderer.js) and the
// miniplayer, so every long title scrolls the same way. A plain script, loaded
// before either page's own; global on purpose, like lyric-karaoke.js.
//
// Measure a clipping container and scroll its .np-scroll-inner if the text
// overflows. As Apple Music does it: a pause, then one way at a steady speed
// with a copy following a gap behind, so the loop is seamless instead of
// sliding back. The page styles .np-scroll-inner (inline-block, nowrap) and
// .marquee-on (no ellipsis, left-aligned) itself.
const MARQUEE = { gap: 48, speed: 30, hold: 2500 }   // px, px/s, ms at the start of each pass
function applyMarquee(el) {
  const inner = el?.querySelector('.np-scroll-inner')
  if (!inner) return
  for (const a of el.getAnimations({ subtree: true })) a.cancel()
  el.querySelectorAll('.np-scroll-copy').forEach(c => c.remove())
  el.classList.remove('marquee-on')
  if (inner.scrollWidth - el.clientWidth <= 4) return   // dead-zone absorbs subpixel rounding
  el.classList.add('marquee-on')
  const copy = inner.cloneNode(true)
  copy.classList.add('np-scroll-copy')
  copy.setAttribute('aria-hidden', 'true')
  copy.querySelectorAll('[id]').forEach(n => n.removeAttribute('id'))
  copy.style.marginLeft = `${MARQUEE.gap}px`
  el.appendChild(copy)
  const dist = inner.offsetWidth + MARQUEE.gap
  const duration = MARQUEE.hold + (dist / MARQUEE.speed) * 1000
  const frames = [
    { transform: 'translateX(0)' },
    { transform: 'translateX(0)', offset: MARQUEE.hold / duration },
    { transform: `translateX(${-dist}px)` },
  ]
  for (const part of [inner, copy]) part.animate(frames, { duration, iterations: Infinity, easing: 'linear' })
}
