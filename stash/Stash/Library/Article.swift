import Foundation

/// The article on a web page without everything around it -- menus, ads,
/// comments, sidebars -- for reading as plain text and pictures, as
/// DEVONthink's clutter-free copies and Safari's Reader do.
///
/// Found by a script run in the page while it's being copied
/// (`PageArchiver`): it scores each block of text's container, much as
/// Mozilla's Readability does, takes the best, and copies it keeping only
/// plain structure. Pictures stay links to the web, so the words are there
/// offline and the pictures when you're online.
struct Article: Codable, Equatable {
    var title: String
    var byline: String
    var site: String
    /// Plain HTML: paragraphs, headings, lists, links, pictures.
    var html: String

    /// A complete page for showing it, in a reading layout that follows
    /// light and dark mode.
    func page(textSize: Double = 1) -> String {
        let heading = Self.escape(title)
        let about = [byline, site].filter { !$0.isEmpty }.map(Self.escape).joined(separator: " · ")
        return """
            <!doctype html>
            <html><head><meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>
            :root { color-scheme: light dark; }
            body { font: \(Int(18 * textSize))px/1.6 -apple-system, "New York", Georgia, serif;
                   max-width: 38em; margin: 0 auto; padding: 1.5em 1.25em 4em; }
            h1 { font-size: 1.7em; line-height: 1.2; margin-bottom: .2em; }
            .about { color: gray; margin-bottom: 2em; }
            img, video { max-width: 100%; height: auto; border-radius: 4px; }
            figure { margin: 1.5em 0; } figcaption { color: gray; font-size: .85em; }
            pre, code { font: .85em ui-monospace, Menlo, monospace; }
            pre { overflow-x: auto; padding: .8em; background: rgba(127,127,127,.12); border-radius: 6px; }
            blockquote { margin-left: 0; padding-left: 1em; border-left: 3px solid rgba(127,127,127,.4); color: gray; }
            table { border-collapse: collapse; } td, th { border: 1px solid rgba(127,127,127,.3); padding: .3em .5em; }
            a { color: -apple-system-blue; }
            </style></head>
            <body><h1>\(heading)</h1>\(about.isEmpty ? "" : "<p class=\"about\">\(about)</p>")
            \(html)
            </body></html>
            """
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Run in the loaded page; returns {title, byline, site, html, length},
    /// or null when there's no article -- a home page, a web app.
    static let script = #"""
(function () {
  const unlikely = /(^|[\s_-])(ad|ads|advert|banner|breadcrumbs?|comments?|cookie|footer|header|menu|modal|nav|newsletter|pagination|popup|promo|related|share|sharing|sidebar|social|sponsor|subscribe|widget|masthead|toolbar|outbrain|taboola|navbox|reflist|references|mw-editsection)([\s_-]|$)/i;
  const likely = /article|body|content|entry|main|post|story|text|prose/i;
  const skipAncestors = 'nav, aside, footer, form, [role="navigation"], [role="complementary"], [aria-hidden="true"]';

  const textOf = (element) => (element.textContent || '').replace(/\s+/g, ' ').trim();
  const classAndId = (element) => {
    const name = typeof element.className === 'string' ? element.className : '';
    return name + ' ' + (element.id || '');
  };
  const linkDensity = (element) => {
    const length = textOf(element).length;
    if (!length) return 0;
    let links = 0;
    element.querySelectorAll('a').forEach((a) => { links += textOf(a).length; });
    return links / length;
  };
  const baseScore = (element) => {
    let score = 0;
    const hints = classAndId(element);
    if (unlikely.test(hints)) score -= 25;
    if (likely.test(hints)) score += 25;
    switch (element.tagName) {
      case 'ARTICLE': score += 15; break;
      case 'MAIN': score += 10; break;
      case 'DIV': score += 5; break;
      case 'SECTION': score += 3; break;
      case 'PRE': case 'TD': case 'BLOCKQUOTE': score += 3; break;
      case 'FORM': case 'UL': case 'OL': case 'DL': score -= 3; break;
      case 'H1': case 'H2': case 'H3': case 'H4': case 'TH': score -= 5; break;
    }
    return score;
  };

  // Remember where each picture really is before copying: lazy-loading
  // pages keep it in data attributes until it scrolls into view.
  document.querySelectorAll('img').forEach((img) => {
    const lazy = img.getAttribute('data-src') || img.getAttribute('data-lazy-src') || img.getAttribute('data-original');
    const source = img.currentSrc || lazy || img.getAttribute('src');
    if (source) img.setAttribute('data-stash-src', source);
  });

  // Score every block of text's parent and grandparent, as Readability does.
  const scores = new Map();
  const add = (element, points) => {
    if (!element || element === document.documentElement || element.tagName === 'BODY') return;
    if (!scores.has(element)) scores.set(element, baseScore(element));
    scores.set(element, scores.get(element) + points);
  };
  document.querySelectorAll('p, pre, td, blockquote').forEach((block) => {
    if (block.closest(skipAncestors)) return;
    const text = textOf(block);
    if (text.length < 25) return;
    const points = 1 + text.split(/[,،、，]/).length + Math.min(Math.floor(text.length / 100), 3);
    add(block.parentElement, points);
    if (block.parentElement) add(block.parentElement.parentElement, points / 2);
  });

  const ranked = [];
  scores.forEach((score, element) => ranked.push({ element, score: score * (1 - linkDensity(element)) }));
  ranked.sort((a, b) => b.score - a.score);
  let best = ranked.length ? ranked[0].element : document.querySelector('article, main, [role="main"]');
  let bestScore = ranked.length ? ranked[0].score : 0;
  if (!best) return null;
  // An article split into sections scores each section on its own; when
  // most of the best few sit inside one element, that's the article.
  const top = ranked.slice(0, 5).filter((entry) => entry.score >= bestScore * 0.3).map((entry) => entry.element);
  let ancestor = best.parentElement;
  for (let level = 0; ancestor && ancestor.tagName !== 'BODY' && level < 3; level++, ancestor = ancestor.parentElement) {
    if (top.length >= 3 && top.filter((element) => ancestor.contains(element)).length >= 3 && linkDensity(ancestor) < 0.5) {
      best = ancestor;
      bestScore = Math.max(bestScore, scores.get(ancestor) || 0);
      break;
    }
  }

  // Siblings that look like more of the same article come too.
  const parts = [];
  const parent = best.parentElement;
  const threshold = Math.max(10, bestScore * 0.2);
  for (const sibling of parent ? parent.children : [best]) {
    if (sibling === best) { parts.push(sibling); continue; }
    const score = scores.has(sibling) ? scores.get(sibling) * (1 - linkDensity(sibling)) : 0;
    const text = textOf(sibling);
    if (score >= threshold || (sibling.tagName === 'P' && text.length > 80 && linkDensity(sibling) < 0.25)) {
      parts.push(sibling);
    }
  }

  // Copy, keeping only plain structure: no scripts, styles, classes or forms.
  const keep = new Set(['P', 'DIV', 'SECTION', 'ARTICLE', 'H1', 'H2', 'H3', 'H4', 'H5', 'H6', 'UL', 'OL', 'LI',
    'BLOCKQUOTE', 'PRE', 'CODE', 'EM', 'I', 'STRONG', 'B', 'A', 'IMG', 'FIGURE', 'FIGCAPTION', 'BR', 'HR',
    'TABLE', 'THEAD', 'TBODY', 'TR', 'TH', 'TD', 'SUP', 'SUB', 'DL', 'DT', 'DD', 'SMALL', 'MARK', 'S', 'U']);
  const drop = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'IFRAME', 'FORM', 'BUTTON', 'INPUT', 'SELECT', 'TEXTAREA',
    'NAV', 'ASIDE', 'FOOTER', 'OBJECT', 'EMBED', 'CANVAS', 'SVG', 'VIDEO', 'AUDIO', 'TEMPLATE', 'DIALOG', 'LINK', 'META']);
  const absolute = (value) => { try { return new URL(value, document.baseURI).href; } catch (e) { return null; } };

  const copy = (node) => {
    if (node.nodeType === Node.TEXT_NODE) return document.createTextNode(node.data);
    if (node.nodeType !== Node.ELEMENT_NODE) return null;
    const tag = node.tagName.toUpperCase();
    if (drop.has(tag)) return null;
    if (node.closest && node !== best && node.getAttribute('aria-hidden') === 'true') return null;
    const hints = classAndId(node);
    if (tag !== 'A' && unlikely.test(hints) && !likely.test(hints) && linkDensity(node) > 0.3) return null;
    if ((tag === 'DIV' || tag === 'SECTION' || tag === 'UL' || tag === 'TABLE') &&
        textOf(node).length < 200 && linkDensity(node) > 0.5 && !node.querySelector('img')) return null;

    if (tag === 'IMG') {
      const source = absolute(node.getAttribute('data-stash-src') || '');
      const width = parseInt(node.getAttribute('width') || '0', 10);
      if (!source || source.startsWith('data:') || (width > 0 && width < 40)) return null;
      const image = document.createElement('img');
      image.setAttribute('src', source);
      if (node.alt) image.setAttribute('alt', node.alt);
      return image;
    }
    // Anything else not kept is unwrapped: its contents stay.
    const element = keep.has(tag) ? document.createElement(tag.toLowerCase()) : document.createDocumentFragment();
    if (tag === 'A') {
      const href = absolute(node.getAttribute('href') || '');
      if (href && !href.startsWith('javascript:')) element.setAttribute('href', href);
    }
    node.childNodes.forEach((child) => {
      const copied = copy(child);
      if (copied) element.appendChild(copied);
    });
    if (keep.has(tag) && tag !== 'BR' && tag !== 'HR' && !element.textContent.trim() && !element.querySelector('img')) {
      return null;
    }
    return element;
  };

  const container = document.createElement('div');
  for (const part of parts) {
    const copied = copy(part);
    if (copied) container.appendChild(copied);
  }
  const text = textOf(container);
  if (text.length < 250) return null;

  const meta = (selector) => {
    const element = document.querySelector(selector);
    return element ? (element.getAttribute('content') || '').trim() : '';
  };
  // The page's own heading inside the article repeats the title.
  const title = meta('meta[property="og:title"]') || document.title || '';
  const first = container.querySelector('h1');
  if (first && textOf(first).toLowerCase() === title.trim().toLowerCase()) first.remove();

  const authorLink = document.querySelector('[rel="author"], .byline, .author');
  return {
    title: title,
    byline: meta('meta[name="author"]') || meta('meta[property="article:author"]') || (authorLink ? textOf(authorLink).slice(0, 120) : ''),
    site: meta('meta[property="og:site_name"]'),
    html: container.innerHTML,
    length: text.length,
  };
})()
"""#
}
