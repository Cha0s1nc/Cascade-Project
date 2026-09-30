// Release notes are Markdown written on GitHub. This renders the part of it
// they actually use: headings, nested lists (tab or space indented), paragraphs,
// rules, and inline bold, italics, strikethrough, code and links.
//
// Everything is escaped before any markup is added, and only http(s) URLs
// become links, so a release body can never inject HTML into the updater.
//
// ponytail: a subset, not CommonMark. No tables, blockquotes, images or
// reference links; swap in a real parser if the notes ever need them.
//
// Loaded as a plain <script> by updater.html and required by the tests.

(function (root) {
  const esc = s => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;')

  function inline(text) {
    // Code spans and links are set aside first so the emphasis rules below
    // cannot reach into them (a URL can contain * or _).
    const held = []
    const hold = html => `\u0000${held.push(html) - 1}\u0000`
    let s = esc(text)
      .replace(/`([^`]+)`/g, (_, code) => hold(`<code>${code}</code>`))
      .replace(/\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)/g, (_, label, url) => hold(`<a href="${url}">${label}</a>`))
      .replace(/(^|[\s(])(https?:\/\/[^\s<)]+)/g, (_, pre, url) => pre + hold(`<a href="${url}">${url}</a>`))
    s = s
      .replace(/\*\*\*(?=\S)(.+?)(?<=\S)\*\*\*/g, '<strong><em>$1</em></strong>')
      .replace(/(\*\*|__)(?=\S)(.+?)(?<=\S)\1/g, '<strong>$2</strong>')
      .replace(/~~(?=\S)(.+?)(?<=\S)~~/g, '<del>$1</del>')
      .replace(/\*(?=\S)([^*]+?)(?<=\S)\*/g, '<em>$1</em>')
      .replace(/(^|[^\w])_(?=\S)([^_]+?)(?<=\S)_(?![\w])/g, '$1<em>$2</em>')
    // Held items can nest (a link label with code), so restore until stable.
    while (/\u0000\d+\u0000/.test(s)) s = s.replace(/\u0000(\d+)\u0000/g, (_, i) => held[i])
    return s
  }

  // Columns of indent, a tab counting as four, so tab- and space-nested lists
  // (GitHub accepts both) line up the same.
  const indentOf = ws => ws.replace(/\t/g, '    ').length

  function renderReleaseNotes(raw) {
    const empty = '<span class="changelog-empty">No release notes available.</span>'
    if (!raw) return empty
    const out = []
    const lists = []   // open lists, innermost last: { indent, tag }
    // Consecutive text lines are one paragraph: CHANGELOG.md wraps its lines.
    let para = []
    const closePara = () => { if (para.length) out.push(`<p>${inline(para.join(' '))}</p>`); para = [] }
    const closeLists = (above = -1) => {
      while (lists.length && lists[lists.length - 1].indent > above) out.push(`</li></${lists.pop().tag}>`)
    }

    for (const line of raw.replace(/\r\n?/g, '\n').split('\n')) {
      const t = line.trimEnd()
      let m
      if ((m = t.match(/^(\s*)([-*+]|\d+[.)])\s+(.*)$/)) && !/^\s*([-*_])(\s*\1){2,}\s*$/.test(t)) {
        closePara()
        const indent = indentOf(m[1])
        const tag = /\d/.test(m[2]) ? 'ol' : 'ul'
        closeLists(indent)
        const top = lists[lists.length - 1]
        if (top && top.indent === indent) out.push(`</li><li>${inline(m[3])}`)
        else { lists.push({ indent, tag }); out.push(`<${tag}><li>${inline(m[3])}`) }
      } else if (t.trim() && lists.length && /^\s/.test(t)) {
        // An indented line under a list item continues that item, as a soft
        // wrap: GitHub joins it with a space, and CHANGELOG.md wraps long items.
        out.push(` ${inline(t.trim())}`)
      } else {
        closeLists()
        if (!t.trim()) { closePara(); continue }
        if ((m = t.match(/^(#{1,6})\s+(.*)$/))) { closePara(); out.push(`<h${m[1].length}>${inline(m[2])}</h${m[1].length}>`) }
        else if (/^\s*([-*_])(\s*\1){2,}\s*$/.test(t)) { closePara(); out.push('<hr>') }
        else para.push(t.trim())
      }
    }
    closePara()
    closeLists()
    return out.join('') || empty
  }

  if (typeof module === 'object' && module.exports) module.exports = { renderReleaseNotes }
  else root.renderReleaseNotes = renderReleaseNotes
})(this)
