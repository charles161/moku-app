package brain

import (
	"net/url"
	"regexp"
	"slices"
	"strings"
)

// Screen is what's in front of the person, reduced to the fields every decision keys on.
type Screen struct {
	BundleID string
	AppName  string
	Title    string
	URL      *string
	TextHash *string
}

func screenOf(s ActivitySample) Screen {
	sc := Screen{BundleID: s.App.BundleID, AppName: s.App.Name, TextHash: s.TextHash}
	if s.Window != nil {
		sc.Title, sc.URL = s.Window.Title, s.Window.URL
	}
	return sc
}

func eqStr(a, b *string) bool {
	if a == nil || b == nil {
		return a == nil && b == nil
	}
	return *a == *b
}

// sameScreen: same app, window title, URL and text: nothing on screen changed.
func sameScreen(a, b Screen) bool {
	return a.BundleID == b.BundleID && a.Title == b.Title && eqStr(a.URL, b.URL) && eqStr(a.TextHash, b.TextHash)
}

// parseWeb parses an http(s) URL the way a browser would for the parts used here, or nil.
func parseWeb(raw *string) *url.URL {
	if raw == nil || *raw == "" {
		return nil
	}
	u, err := url.Parse(*raw)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Hostname() == "" {
		return nil
	}
	return u
}

var wwwPrefix = regexp.MustCompile(`^www\.`)

// siteOf: `www.youtube.com` → `youtube.com`; nil for anything that isn't an http(s) URL.
func siteOf(raw *string) *string {
	u := parseWeb(raw)
	if u == nil {
		return nil
	}
	host := wwwPrefix.ReplaceAllString(strings.ToLower(u.Hostname()), "")
	return &host
}

func deref(p *string) string {
	if p == nil {
		return ""
	}
	return *p
}

func ptr[T any](v T) *T { return &v }

// onSite: `m.youtube.com` is on `youtube.com`; `notyoutube.com` is not.
func onSite(host *string, site string) bool {
	return host != nil && (*host == site || strings.HasSuffix(*host, "."+site))
}

var trailingSlashes = regexp.MustCompile(`/+$`)

// webPath: the URL's path as a browser writes it (percent-encoded).
func webPath(u *url.URL) string {
	p := u.EscapedPath()
	if p == "" {
		p = "/"
	}
	return p
}

// pathOf: the path without a trailing slash ("/" for the root), or nil for a non-web URL.
func pathOf(raw *string) *string {
	u := parseWeb(raw)
	if u == nil {
		return nil
	}
	p := trailingSlashes.ReplaceAllString(webPath(u), "")
	if p == "" {
		p = "/"
	}
	return &p
}

// hostAndPath: host and path only (queries and fragments carry tokens and ids, and stay on the Mac).
func hostAndPath(raw *string) *string {
	site := siteOf(raw)
	if site == nil {
		return nil
	}
	path := trailingSlashes.ReplaceAllString(webPath(parseWeb(raw)), "")
	out := Clip(*site+path, 160)
	return &out
}

var (
	unreadCounter = regexp.MustCompile(`^\(\d+\+?\)` + jsSpace + `*`)
	unsavedMarker = regexp.MustCompile(`^[●•*]` + jsSpace + `*`)
)

// normalizeTitle drops what changes while the context stays: unread counters ("(3) Inbox"), unsaved markers
// ("● main.ts"), and the app's own name as a suffix.
func normalizeTitle(title, appName string) string {
	t := unsavedMarker.ReplaceAllString(unreadCounter.ReplaceAllString(strings.ToLower(title), ""), "")
	app := Trim(strings.ToLower(appName))
	if app != "" {
		t = regexp.MustCompile(jsSpace+`+[-–—|]`+jsSpace+`+`+regexp.QuoteMeta(app)+`$`).ReplaceAllString(t, "")
	}
	return Trim(spaceRun.ReplaceAllString(t, " "))
}

// screenKey: "the exact same screen" (shares an in-flight Jev call).
func screenKey(s Screen) string {
	return JSON([]any{s.BundleID, s.Title, s.URL, s.TextHash})
}

// placeOf: the site for web pages, else the app.
func placeOf(s Screen) string {
	if site := siteOf(s.URL); site != nil {
		return *site
	}
	return s.AppName
}

// isWatchable: rule away's exception: a feed or streaming page, a video site, or a video player app.
func isWatchable(s Screen) bool {
	host := siteOf(s.URL)
	if _, _, ok := knownFeedPage(s.URL); ok {
		return true
	}
	for _, site := range Rules.Away.WatchableSites {
		if onSite(host, site) {
			return true
		}
	}
	return slices.Contains(Rules.Away.WatchableBundleIDs, s.BundleID)
}

// frontPage: rule front-page: a news site's front page or a shop's home page (exact host, www. aside).
func frontPage(raw *string) (kind, page string, ok bool) {
	host, path := siteOf(raw), pathOf(raw)
	if host == nil || path == nil {
		return "", "", false
	}
	for _, k := range []string{"news", "shopping"} {
		table := Rules.FrontPage.News
		if k == "shopping" {
			table = Rules.FrontPage.Shopping
		}
		if paths, found := table[*host]; found && slices.Contains(paths, *path) {
			p := *host
			if *path != "/" {
				p += *path
			}
			return k, p, true
		}
	}
	return "", "", false
}

// driftApp: rule drift-app: a game, or a video or music app, by bundle id.
func driftApp(bundleID string) string {
	g := Rules.DriftApp
	if slices.Contains(g.GameBundleIDs, bundleID) || slices.ContainsFunc(g.GamePrefixes, func(p string) bool { return strings.HasPrefix(bundleID, p) }) {
		return "game"
	}
	if slices.Contains(g.Video, bundleID) {
		return "video"
	}
	if slices.Contains(g.Music, bundleID) {
		return "music"
	}
	return ""
}

// knownFeedPage: a page on rule known-feed's lists: a feed or home page, or a streaming site.
func knownFeedPage(raw *string) (kind, page string, ok bool) {
	host, path := siteOf(raw), pathOf(raw)
	if host == nil || path == nil {
		return "", "", false
	}
	for _, site := range Rules.KnownFeed.Streaming {
		if onSite(host, site) {
			return "streaming", site, true
		}
	}
	for _, feed := range Rules.KnownFeed.FeedPages {
		if !onSite(host, feed.Site) {
			continue
		}
		for _, p := range feed.Prefixes {
			if (p == "/" && *path == "/") || (p != "/" && (*path == p || strings.HasPrefix(*path, p+"/"))) {
				page := feed.Site
				if *path != "/" {
					page += *path
				}
				return "feed", page, true
			}
		}
	}
	return "", "", false
}

// parseAnyURL: the path of any absolute URL (new URL(url).pathname), or "" when it doesn't parse.
func parseAnyURL(raw string) string {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme == "" {
		return ""
	}
	return u.EscapedPath()
}
