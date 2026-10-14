#!/usr/bin/env python3
"""The launch-QA screen catalogue (docs/specs/launch-qa.md, lens 2): realistic screens for a writer, a designer, a coder,
a student, meetings, dictation, research that looks like browsing, and real drifts.

    python3 scripts/qa-screens.py        # rewrites brain-go/internal/brain/testdata/qa/screens.json

Each screen is what the sense layer would hand the brain for one window: app, window title, address, and the text on it
(a short excerpt, as accessibility or OCR would read it). `truth` is what a person would say it is by default: work,
drift, neutral (a utility: neither), or meeting. A session script (app/MokuMind/Sources/mokumind-qa) can override the
truth for a segment (the same Hacker News page is a drift on a coffee break and research while looking for a library).

The Go tests record the real Jev's answer for each screen the rules don't decide (`qa_live_test.go`, MOKU_LIVE=1) into
testdata/qa/jev-tape.json; the QA brain replays that tape, so sessions of any length cost no model calls.
"""
import json, pathlib

OUT = pathlib.Path(__file__).resolve().parent.parent / "brain-go/internal/brain/testdata/qa/screens.json"

APPS = {
    "chrome": ("com.google.Chrome", "Google Chrome"), "safari": ("com.apple.Safari", "Safari"),
    "pages": ("com.apple.iWork.Pages", "Pages"), "notion": ("notion.id", "Notion"),
    "cursor": ("com.todesktop.230313mzl4w4u92", "Cursor"), "vscode": ("com.microsoft.VSCode", "Code"),
    "xcode": ("com.apple.dt.Xcode", "Xcode"), "terminal": ("com.apple.Terminal", "Terminal"),
    "iterm": ("com.googlecode.iterm2", "iTerm2"), "warp": ("dev.warp.Warp-Stable", "Warp"),
    "alacritty": ("org.alacritty", "Alacritty"), "figma": ("com.figma.Desktop", "Figma"),
    "photoshop": ("com.adobe.Photoshop", "Adobe Photoshop 2026"), "sketch": ("com.bohemiancoding.sketch3", "Sketch"),
    "illustrator": ("com.adobe.illustrator", "Adobe Illustrator 2026"), "blender": ("org.blenderfoundation.blender", "Blender"),
    "preview": ("com.apple.Preview", "Preview"), "finder": ("com.apple.finder", "Finder"),
    "slack": ("com.tinyspeck.slackmacgap", "Slack"), "mail": ("com.apple.mail", "Mail"),
    "notes": ("com.apple.Notes", "Notes"), "obsidian": ("md.obsidian", "Obsidian"), "zotero": ("org.zotero.zotero", "Zotero"),
    "anki": ("net.ankiweb.dtop", "Anki"), "pdfexpert": ("com.readdle.PDFExpert-Mac", "PDF Expert"),
    "acrobat": ("com.adobe.Reader", "Adobe Acrobat Reader"), "zoom": ("us.zoom.xos", "zoom.us"),
    "teams": ("com.microsoft.teams2", "Microsoft Teams"), "facetime": ("com.apple.FaceTime", "FaceTime"),
    "spotify": ("com.spotify.client", "Spotify"), "whatsapp": ("net.whatsapp.WhatsApp", "WhatsApp"),
    "telegram": ("ru.keepcoder.Telegram", "Telegram"), "discord": ("com.hnc.Discord", "Discord"),
    "messages": ("com.apple.MobileSMS", "Messages"), "steam": ("com.valvesoftware.steam", "Steam"),
    "minecraft": ("com.mojang.minecraftlauncher", "Minecraft Launcher"), "wispr": ("com.electron.wispr-flow", "Wispr Flow"),
    "login": ("com.apple.loginwindow", "loginwindow"), "word": ("com.microsoft.Word", "Microsoft Word"),
    "androidstudio": ("com.google.android.studio", "Android Studio"), "claude": ("com.anthropic.claudefordesktop", "Claude"),
    "postman": ("com.postmanlabs.mac", "Postman"), "docker": ("com.docker.docker", "Docker Desktop"),
    "linear": ("com.linear", "Linear"), "tableplus": ("com.tinyapp.TablePlus", "TablePlus"),
}

screens = []


def S(id, app, title, text="", url=None, truth="work", who=(), note=""):
    bundle, name = APPS[app]
    entry = {"id": id, "app": name, "bundle": bundle, "title": title, "text": text, "truth": truth, "who": list(who)}
    if url:
        entry["url"] = url
    if note:
        entry["note"] = note
    screens.append(entry)


# ───────────── The writer: a long magazine essay on the printing press ─────────────
W = ("writer",)
S("w-docs", "chrome", "The Press That Remade Europe - Google Docs", url="https://docs.google.com/document/d/1xKq2/edit", who=W,
  text="The Press That Remade Europe. When Johannes Gutenberg pulled the first sheets from his press in Mainz around 1450, he did not know that he was dismantling a monopoly. Before him, a book was a year of a scribe's life. After him, it was an afternoon in a workshop. The consequences arrived slowly, then all at once. By 1500, some twenty million volumes")
S("w-pages", "pages", "Draft 3 - The Press That Remade Europe.pages", who=W,
  text="The Press That Remade Europe. Draft 3. Section 4: The workshop. A printing house in 1480 was a noisy, inky, dangerous place. Compositors set type letter by letter from the case, pressmen pulled the bar, and boys carried wet sheets to the lines to dry.")
S("w-notion", "notion", "Research notes - Printing press", who=W,
  text="Research notes. Printing press. To check: number of surviving Gutenberg Bibles (49 or 48?). Venice 1470s: Aldus Manutius, italic type. Elizabeth Eisenstein, The Printing Press as an Agent of Change. Questions for the interview with Dr Hale.")
S("w-wiki", "safari", "Printing press - Wikipedia", url="https://en.wikipedia.org/wiki/Printing_press", who=W,
  text="Printing press. From Wikipedia, the free encyclopedia. A printing press is a mechanical device for applying pressure to an inked surface resting upon a medium, thereby transferring the ink. The mechanical movable-type printing press, introduced by Johannes Gutenberg in the mid-15th century, spread rapidly across Europe. Contents: 1 History 2 Gutenberg 3 Spread of printing 4 Impact")
S("w-search", "safari", "gutenberg bible copies surviving - Google Search", url="https://www.google.com/search?q=gutenberg+bible+copies+surviving", who=W,
  text="gutenberg bible copies surviving. All Images News Books. How many Gutenberg Bibles are left? 49 known copies. Gutenberg Bible - Wikipedia. Surviving copies of the Gutenberg Bible - British Library. People also ask: Where are the Gutenberg Bibles today?")
S("w-cambridge", "safari", "The Printing Revolution in Early Modern Europe | Cambridge Core", url="https://www.cambridge.org/core/books/printing-revolution-in-early-modern-europe/ABCD", who=W,
  text="The Printing Revolution in Early Modern Europe. Elizabeth L. Eisenstein. Publisher: Cambridge University Press. Online publication: 5 June 2012. Chapter 1. Introduction. Abstract: this abridged edition examines the role of the printing press in the transformation of European society.")
S("w-nyt", "safari", "A Bible That Changed the World, Page by Page - The New York Times", url="https://www.nytimes.com/2024/05/12/books/review/gutenberg-bible-book.html", who=W,
  text="A Bible That Changed the World, Page by Page. By Marianne Cole. May 12, 2024. In a locked vault in Mainz, a conservator turns a leaf of vellum with tweezers. The book on the table is not the oldest printed Bible, nor the most beautiful, but it is the one every history of the press begins with.")
S("w-yt-lecture", "safari", "The Gutenberg Revolution: How Printing Changed Europe | Oxford Lecture - YouTube", url="https://www.youtube.com/watch?v=Zq81ABCdE", who=W,
  text="The Gutenberg Revolution: How Printing Changed Europe. Oxford University. 412K views. Professor Alison Hale explains how movable type reshaped religion, science and politics in the century after 1450. Chapters: 0:00 Introduction 4:12 The workshop 18:40 The Reformation 41:05 Questions. Comments 1,204")
S("w-reddit-ask", "safari", "How many Gutenberg Bibles survive today and how do we know? : r/AskHistorians", url="https://www.reddit.com/r/AskHistorians/comments/1abc23/how_many_gutenberg_bibles_survive_today/", who=W,
  text="r/AskHistorians. How many Gutenberg Bibles survive today and how do we know? Asked by u/inkandvellum. Top answer by u/medievalist: Forty-nine copies are known in whole or in part, and the census is maintained by the Incunabula Short Title Catalogue at the British Library.")
S("w-thesaurus", "safari", "ELOQUENT Synonyms: 120 Similar and Opposite Words | Thesaurus.com", url="https://www.thesaurus.com/browse/eloquent", who=W,
  text="eloquent. adjective. expressive, fluent, articulate. Synonyms for eloquent: articulate, fluent, silver-tongued, persuasive, graceful, well-spoken, vivid, moving. Antonyms: inarticulate, tongue-tied.")
S("w-hemingway", "chrome", "Hemingway Editor", url="https://hemingwayapp.com/", who=W,
  text="Hemingway Editor. Grade 9. Good. 1 of 14 sentences is very hard to read. 3 adverbs. 2 uses of passive voice. Write. Edit. The press did not so much invent reading as make it cheap enough to need.")
S("w-substack", "chrome", "On the lost art of the long paragraph - by Sana Lund", url="https://sanalund.substack.com/p/on-the-lost-art-of-the-long-paragraph", who=W,
  text="On the lost art of the long paragraph. Sana Lund. Sep 22. A paragraph is a unit of thought, not of screen height. Somewhere between the typewriter and the phone, we began to cut our thoughts to fit the glass.")
S("w-gmail", "chrome", "Inbox (4) - editor@longreads.example - Gmail", url="https://mail.google.com/mail/u/0/#inbox", who=W,
  text="Inbox. Priya (Features): Re: Press essay, can you send the photo captions? Accounts: your invoice is paid. Dr Hale: Thursday works for the interview.")
S("w-slack", "slack", "editors-desk | Longreads | Slack", who=W,
  text="editors-desk. Priya: how's the press piece coming? You: draft 3 tonight, captions tomorrow. Priya: perfect, legal wants to see the Bible provenance paragraph.")
S("w-preview", "preview", "Gutenberg-Bible-facsimile.pdf", who=W, truth="neutral",
  text="Gutenberg Bible facsimile. Biblia Latina. Folio 1r. Incipit epistola sancti Hieronymi ad Paulinum presbyterum de omnibus divinae historiae libris.")
S("w-finder", "finder", "Downloads", who=W, truth="neutral", text="Downloads. Gutenberg-Bible-facsimile.pdf. captions-v2.docx. invoice-sept.pdf")
S("w-spotify", "spotify", "Spotify - Deep Focus", who=W, truth="work",
  text="Deep Focus. Peaceful piano to help you concentrate. Now playing: Nils Frahm, Says. Next: Max Richter, On the Nature of Daylight.",
  note="A song change while writing: truth is work, a glance")
S("w-bbc-front", "safari", "BBC News - Home", url="https://www.bbc.com/news", who=W, truth="drift",
  text="BBC News. Home. Israel, Ukraine, US election, Climate. Top stories: Storm hits east coast. Markets fall. Football: transfer deadline day.")
S("w-x-home", "safari", "Home / X", url="https://x.com/home", who=W, truth="drift", text="Home. For you. Following. What is happening. Trending in India. Post. Reply. Repost. Like.")
S("w-ig-feed", "safari", "Instagram", url="https://www.instagram.com/", who=W, truth="drift", text="Instagram. Home. Stories. Suggested for you. Liked by friends. Reels.")
S("w-bbc-article", "safari", "Storm hits east coast as thousands lose power - BBC News", url="https://www.bbc.com/news/uk-66123456", who=W, truth="drift",
  text="Storm hits east coast as thousands lose power. Thousands of homes are without electricity after a storm brought winds of up to 80mph. Engineers said it could be days before supply is fully restored.")

# ───────────── The designer: a brand identity for a coffee roaster ─────────────
D = ("designer",)
S("d-figma", "figma", "Ember Roasters - Logo explorations", who=D, text="Logo explorations. Frame 12. Auto layout. Fill. Stroke. Effects. Export. Ember wordmark v4. Flame mark.")
S("d-ps", "photoshop", "bag-label-mockup.psd @ 66% (Layer 12, RGB/8)", who=D,
  text="File Edit Image Layer Type Select Filter 3D View Window Help. Layers. Channels. Paths. Properties. Adjustments. Libraries. Opacity 100%. Fill 100%. bag-label-mockup. Smart Object.")
S("d-sketch", "sketch", "Packaging dieline - Edited", who=D, text="Packaging dieline. Page 1. Artboard 340 x 520. Inspector. Style. Layer List. Symbols. Insert. Create Symbol.")
S("d-ai", "illustrator", "bag-front.ai @ 100% (RGB/Preview)", who=D, text="Illustrator. Layers. Properties. Appearance. Pathfinder. Align. bag-front. Artboard 1. Pen Tool.")
S("d-blender", "blender", "Blender [roast-bag-3d.blend]", who=D, text="Blender. Layout Modeling Sculpting UV Editing Texture Paint Shading Animation Rendering. Scene Collection. Cube. Camera. Light.")
S("d-pinterest", "chrome", "Coffee packaging inspiration - Pinterest", url="https://www.pinterest.com/emberroasters/coffee-packaging-inspiration/", who=D,
  text="Coffee packaging inspiration. 84 Pins. Minimal coffee bag design. Kraft paper roaster label. Coffee brand identity, Studio Frank. Retro coffee tin. Save. Visit. More ideas.")
S("d-dribbble", "chrome", "Coffee Roaster Branding by Mira Okafor on Dribbble", url="https://dribbble.com/shots/22914532-Coffee-Roaster-Branding", who=D,
  text="Coffee Roaster Branding. Mira Okafor. Brand identity for a small-batch roaster: wordmark, bag system, stickers. 1.2k views. 214 likes. More by Mira Okafor. Available for work.")
S("d-dribbble-home", "chrome", "Dribbble - Discover the World's Top Designers & Creative Professionals", url="https://dribbble.com/", who=D,
  text="Discover the world's top designers and creative professionals. Popular. New and Noteworthy. Following. Branding. Illustration. Mobile. Web design. Shot. Like. Save.")
S("d-behance", "chrome", "Ember Coffee Brand Identity on Behance", url="https://www.behance.net/gallery/188233545/Ember-Coffee-Brand-Identity", who=D,
  text="Ember Coffee Brand Identity. Behance. Studio Norte. Branding, Packaging, Graphic Design. 3,104 appreciations. Project info. Tools used: Illustrator, Photoshop.")
S("d-awwwards", "chrome", "Ember Roasters - Awwwards Site of the Day", url="https://www.awwwards.com/sites/ember-roasters", who=D,
  text="Ember Roasters. Site of the Day. Design 7.9. Usability 7.4. Creativity 8.1. Content 7.6. Visit site. Technology: WebGL, GSAP.")
S("d-arena", "chrome", "Roastery mood - Are.na", url="https://www.are.na/charles-m/roastery-mood", who=D, text="Roastery mood. 58 blocks. Channel by Charles M. Burlap sack texture. Vintage grinder. Hand-lettered chalkboard menu.")
S("d-gfonts", "chrome", "DM Serif Display - Google Fonts", url="https://fonts.google.com/specimen/DM+Serif+Display", who=D,
  text="DM Serif Display. Designed by Colophon Foundry. Type tester. Regular 400. Whereas disregard and contempt for human rights. Glyphs. Styles. About. License. Get font.")
S("d-coolors", "chrome", "Coolors - The super fast color palettes generator", url="https://coolors.co/palette/6f4e37-c68b59-f5e6d3-2d1b12", who=D,
  text="Coolors. Generate your palette. Press the spacebar to generate color palettes. 6F4E37 C68B59 F5E6D3 2D1B12. Export palette. Save.")
S("d-canva", "chrome", "Untitled design - Canva", url="https://www.canva.com/design/DAFxyz/edit", who=D, text="Untitled design. Canva. Design. Elements. Text. Brand. Uploads. Share. Position. Animate.")
S("d-yt-tut", "chrome", "Figma Auto Layout 5.0 Full Tutorial (2025) - YouTube", url="https://www.youtube.com/watch?v=FgLayOut5", who=D,
  text="Figma Auto Layout 5.0 Full Tutorial. Design Course. 286K views. In this tutorial we cover auto layout wrap, min and max sizes, and nested frames. Chapters 0:00 Intro 3:20 Wrap 9:15 Min and max. 842 comments.")
S("d-ig-studio", "chrome", "Pentagram (@pentagram) - Instagram photos and videos", url="https://www.instagram.com/pentagram/", who=D,
  text="Pentagram. 1.2M followers. 3,412 posts. Design studio. New identity for a museum. Packaging for a tea brand. Posters for a festival. Follow. Message.",
  note="design reference on a social site")
S("d-slack", "slack", "design-crit | Ember | Slack", who=D, text="design-crit. Ana: the kraft bag reads better with the flame in the corner. You: agreed, trying a second option tonight.")
S("d-yt-home", "chrome", "YouTube", url="https://www.youtube.com/", who=D, truth="drift", text="YouTube. Home. Recommended. Trending. Music. Gaming. Subscriptions. Library.")

# ───────────── The coder: a Go service and a React dashboard ─────────────
C = ("coder",)
S("c-cursor", "cursor", "handler.go - dashboard-api", who=C, text="package api func (h *Handler) Judge(w http.ResponseWriter, r *http.Request) { ctx, cancel := context.WithTimeout(r.Context(), 7*time.Second) defer cancel()")
S("c-vscode", "vscode", "App.tsx - dashboard-web", who=C, text="export default function App() { const [rows, setRows] = useState<Row[]>([]) useEffect(() => { fetch('/api/rows').then(r => r.json()).then(setRows) }, [])")
S("c-xcode", "xcode", "LoginView.swift", who=C, text="struct LoginView: View { @State private var email = String() var body: some View { Form { TextField(Email, text: $email) } } }")
S("c-term", "terminal", "charles - zsh - 120x32", who=C, text="$ go test ./... ok moku/brain/internal/brain 4.212s ok moku/brain/internal/world 0.8s $ git status On branch qa-behaviour")
S("c-iterm", "iterm", "npm run dev", who=C, text="VITE v6.0.1 ready in 412 ms Local: http://localhost:5173/ Network: use --host to expose press h + enter to show help")
S("c-warp", "warp", "~/dashboard-api", who=C, text="warp. ~/dashboard-api git:(main) $ make test Running 124 tests... 124 passed")
S("c-alacritty", "alacritty", "nvim", who=C, text="nvim. handler.go [+] 148,12 All. -- INSERT -- func (h *Handler) Judge(")
S("c-androidstudio", "androidstudio", "MainActivity.kt - app", who=C, text="MainActivity.kt. class MainActivity : ComponentActivity() { override fun onCreate(savedInstanceState: Bundle?) { super.onCreate(savedInstanceState) setContent { AppTheme { Greeting() } } } }")
S("c-obsidian", "obsidian", "Architecture notes - dev-vault - Obsidian v1.8.4", who=C, text="Architecture notes. Queue consumer design. At-least-once delivery, idempotency keys. [[Judge pipeline]] [[Rate limits]] TODO: decide on backoff.")
S("c-gh-pr", "chrome", "Add rate limiting to /v1/judge by charles-m - Pull Request #482 - acme/dashboard-api", url="https://github.com/acme/dashboard-api/pull/482", who=C,
  text="Add rate limiting to /v1/judge #482. Open. charles-m wants to merge 3 commits into main from rate-limit. Conversation 4. Commits 3. Checks 12. Files changed 5. Reviewers: priya-dev. All checks have passed.")
S("c-gh-actions", "chrome", "CI - Run 9921 - acme/dashboard-api", url="https://github.com/acme/dashboard-api/actions/runs/9921", who=C,
  text="CI. Run 9921. Triggered via push 4 minutes ago. Status: in progress. Jobs: build, test (go 1.25), lint. test: running step 6 of 9.")
S("c-so", "chrome", "go - How do I cancel a context from another goroutine? - Stack Overflow", url="https://stackoverflow.com/questions/58475332/how-do-i-cancel-a-context-from-another-goroutine", who=C,
  text="How do I cancel a context from another goroutine? Asked 5 years ago. Viewed 41k times. I create a context with context.WithCancel and want to stop a worker... Accepted answer: call the cancel function returned by WithCancel. Score 62.")
S("c-mdn", "chrome", "IntersectionObserver - Web APIs | MDN", url="https://developer.mozilla.org/en-US/docs/Web/API/IntersectionObserver", who=C,
  text="IntersectionObserver. The IntersectionObserver interface of the Intersection Observer API provides a way to asynchronously observe changes in the intersection of a target element with an ancestor element or with a top-level document's viewport.")
S("c-pkggo", "chrome", "http package - net/http - Go Packages", url="https://pkg.go.dev/net/http", who=C,
  text="http package. Package http provides HTTP client and server implementations. Get, Head, Post, and PostForm make HTTP (or HTTPS) requests. Index. Constants. Variables. func Get(url string) (resp *Response, err error)")
S("c-localhost", "chrome", "Dashboard - Acme", url="http://localhost:5173/", who=C, text="Acme Dashboard. Overview. Requests per minute 1,284. Error rate 0.2%. p95 latency 212 ms. Recent deployments. Settings.")
S("c-sentry", "chrome", "TypeError: Cannot read properties of undefined (reading 'rows') - Sentry", url="https://sentry.io/organizations/acme/issues/48211/", who=C,
  text="TypeError: Cannot read properties of undefined (reading rows). dashboard-web. 214 events. 38 users. First seen 2 days ago. Stack trace: App.tsx line 41 in useRows.")
S("c-yt-talk", "chrome", "Simple Made Easy - Rich Hickey - YouTube", url="https://www.youtube.com/watch?v=SxdOUGdseq4", who=C,
  text="Simple Made Easy. Strange Loop. 1.1M views. Rich Hickey emphasizes simplicity as a prerequisite for reliability. Simple versus easy. Complecting. Chapters. Comments 3,120.")
S("c-medium", "chrome", "Understanding React Server Components | by Dan Reyes | Medium", url="https://medium.com/@danreyes/understanding-react-server-components-4f2a9", who=C,
  text="Understanding React Server Components. Dan Reyes. 9 min read. Server Components render on the server and send a serialized tree to the client. They never ship their dependencies to the browser.")
S("c-leetcode", "chrome", "LRU Cache - LeetCode", url="https://leetcode.com/problems/lru-cache/", who=C,
  text="146. LRU Cache. Medium. Design a data structure that follows the constraints of a Least Recently Used cache. Implement the LRUCache class: get(key), put(key, value). Example 1. Constraints 1 <= capacity <= 3000")
S("c-hn-item", "chrome", "SQLite is not a toy database | Hacker News", url="https://news.ycombinator.com/item?id=41234567", who=C,
  text="SQLite is not a toy database. 412 points by someone 5 hours ago | 188 comments. throwaway: We ran 2TB on SQLite in production for two years. WAL mode and a single writer were all we needed.",
  note="a technical thread: research or a break, by intent")
S("c-reddit-golang", "chrome", "Anyone else hit this context cancellation bug? : r/golang", url="https://www.reddit.com/r/golang/comments/1x2y3z/anyone_else_hit_this_context_cancellation_bug/", who=C,
  text="r/golang. Anyone else hit this context cancellation bug? u/gopherfan: my handler keeps returning context canceled after the client disconnects. Top comment: check whether you pass r.Context() into the goroutine.")
S("c-claude", "claude", "Claude", who=C, text="Claude. How can I help? You: why does my limiter allow a burst of 11 when rate is 10? Claude: your token bucket refills before the check.")
S("c-claudeweb", "chrome", "Rate limiter design - Claude", url="https://claude.ai/chat/9f2a", who=C, text="Rate limiter design. You: sketch a token bucket in Go. Claude: here is a minimal implementation with a mutex.")
S("c-linear", "linear", "ENG-482 Rate limit /v1/judge - Linear", who=C, text="ENG-482. Rate limit /v1/judge. In Progress. Assignee Charles. Priority High. Sub-issues 3.")
S("c-postman", "postman", "POST /v1/judge - Postman", who=C, text="POST http://localhost:8020/v1/judge. Body raw JSON. Send. 200 OK 312 ms. Pretty Raw Preview.")
S("c-tableplus", "tableplus", "acme_prod - verdicts", who=C, text="TablePlus. verdicts. 12,340 rows. id state ts source reason. SELECT * FROM verdicts ORDER BY ts DESC LIMIT 100;")
S("c-docker", "docker", "Docker Desktop", who=C, text="Containers. dashboard-api running 0.4% CPU. postgres running. redis exited. Images. Volumes. Builds.")
S("c-slack", "slack", "eng-backend | Acme | Slack", who=C, text="eng-backend. Priya: review for 482 please. You: on it. Ravi: deploy freeze at 5.")
S("c-hn-front", "chrome", "Hacker News", url="https://news.ycombinator.com/", who=C, truth="drift", text="Hacker News. new | past | comments | ask | show | jobs | submit. 1. Show HN: a tiny database (sqlite.org) 412 points 2. Ask HN: How do you stay focused? 188 points")

# ───────────── The student: organic chemistry and CS 101 ─────────────
T = ("student",)
S("s-preview-pdf", "preview", "Organic Chemistry - Chapter 7.pdf", who=T, truth="neutral",
  text="Chapter 7. Nucleophilic substitution. The SN2 reaction proceeds with inversion of configuration. Rate = k[nucleophile][substrate].")
S("s-pdfexpert", "pdfexpert", "Clayden Organic Chemistry - Ch.7 Nucleophilic substitution", who=T,
  text="Chapter 7. Nucleophilic substitution at saturated carbon. In the SN2 reaction the nucleophile attacks from the side opposite the leaving group. Figure 7.3. Highlighted: inversion of configuration.")
S("s-zotero", "zotero", "My Library - Zotero", who=T, text="My Library. Collections. CHEM 201 papers. Wiberg 1965 Mechanisms of substitution. Item pane. Abstract. Tags. Related.")
S("s-notes", "notes", "Lecture 12 - Thermodynamics", who=T, text="Lecture 12 Thermodynamics. Entropy: S = k ln W. Second law: entropy of an isolated system never decreases. Carnot cycle efficiency = 1 - Tc/Th. Remember: exam covers ch 4 to 7.")
S("s-obsidian", "obsidian", "CS101 - Week 5 - student-vault - Obsidian v1.8.4", who=T, text="CS101 Week 5. Recursion. Base case, recursive case. Stack frames. [[Big O]] Example: factorial(5) = 5 * factorial(4).")
S("s-anki", "anki", "Organic Chem Reactions - Anki", who=T, text="Organic Chem Reactions. Due 42. New 10. Front: What does SN1 stand for? Show Answer. Again Hard Good Easy.")
S("s-canvas", "chrome", "Assignments: CHEM 201", url="https://canvas.instructure.com/courses/48211/assignments", who=T,
  text="CHEM 201 Organic Chemistry I. Assignments. Upcoming. Lab Report 3: due Friday 11:59pm. Problem Set 6: due Oct 9. Past. Quiz 2. Grades. Modules.")
S("s-coursera", "chrome", "Gradient descent | Coursera", url="https://www.coursera.org/learn/machine-learning/lecture/GFFPB/gradient-descent", who=T,
  text="Machine Learning. Week 1. Gradient descent. Have some function J(theta0, theta1). Want min J. Start with some theta, keep changing theta to reduce J. Transcript. Notes. Downloads. Mark as completed.")
S("s-yt-mit", "chrome", "Lecture 5: Dynamic Programming | MIT 6.006 Introduction to Algorithms - YouTube", url="https://www.youtube.com/watch?v=OQ5jsbhAv_M", who=T,
  text="Lecture 5: Dynamic Programming. MIT OpenCourseWare. 1.8M views. Introduction to Algorithms (Spring 2020). Instructor: Erik Demaine. Topics: memoization, subproblems, DAG shortest paths. Transcript. Comments 2,310.")
S("s-yt-crash", "chrome", "SN2 Reaction Mechanism - Organic Chemistry - YouTube", url="https://www.youtube.com/watch?v=sn2mech12", who=T,
  text="SN2 Reaction Mechanism. Organic Chemistry Tutor. 902K views. This video explains the SN2 reaction mechanism, rate law, stereochemistry and solvent effects. Examples and practice problems. 0:00 Intro 2:10 Rate law")
S("s-quizlet", "chrome", "Organic Chemistry Reactions Flashcards | Quizlet", url="https://quizlet.com/483221/organic-chemistry-reactions-flash-cards/", who=T,
  text="Organic Chemistry Reactions. 84 terms. Flashcards. Learn. Test. Match. SN2: bimolecular nucleophilic substitution with inversion. E2: concerted elimination.")
S("s-overleaf", "chrome", "Lab Report 3 - Overleaf, Online LaTeX Editor", url="https://www.overleaf.com/project/64f1a2b3", who=T,
  text="Lab Report 3. Overleaf. Source. Recompile. documentclass article. begin document. section Introduction. The rate of the reaction was measured by titration. Output PDF.")
S("s-scholar", "chrome", "SN2 stereochemistry inversion - Google Scholar", url="https://scholar.google.com/scholar?q=sn2+stereochemistry+inversion", who=T,
  text="Google Scholar. SN2 stereochemistry inversion. About 41,200 results. Walden inversion and the SN2 mechanism. Cited by 312. Related articles. All 6 versions.")
S("s-wolfram", "chrome", "integrate x^2 sin x - Wolfram|Alpha", url="https://www.wolframalpha.com/input?i=integrate+x%5E2+sin+x", who=T,
  text="Wolfram Alpha. integrate x^2 sin x. Indefinite integral: integral x^2 sin(x) dx = 2 x sin(x) + (2 - x^2) cos(x) + constant. Step-by-step solution. Plots.")
S("s-word", "word", "Lab Report 3.docx", who=T, text="Lab Report 3. Aim. To determine the rate constant of the hydrolysis of tert-butyl chloride. Method. Results. Table 1.")
S("s-gdocs", "chrome", "CS101 essay draft - Google Docs", url="https://docs.google.com/document/d/1student/edit", who=T, text="CS101 essay draft. Why recursion matters. Recursion is the idea that a problem can be solved by solving smaller copies of itself.")
S("s-chatgpt", "chrome", "ChatGPT", url="https://chatgpt.com/c/5a1", who=T, text="ChatGPT. Explain SN2 vs SN1 like I am a first-year student. SN2 is one step, SN1 has a carbocation intermediate.")
S("s-discord-study", "discord", "#study-group | CHEM 201 - Discord", who=T, text="CHEM 201. #study-group. Mira: anyone got the answer to q4? Ravi: it is 2-bromobutane, inversion. Jo: meet at the library at 5?")
S("s-whatsapp-class", "whatsapp", "WhatsApp", who=T, text="CS101 Class Group. Prof. Rao: Assignment 3 deadline extended to Monday. Ananya: thanks sir! Karthik: can someone share the lecture slides?")
S("s-zoom-lecture", "zoom", "Zoom Meeting", who=T, text="Zoom Meeting. CHEM 201 Lecture 14. Participants 212. Dr. Patel is presenting. Chat. Raise hand.")

# ───────────── Meetings and calls, back to back ─────────────
M = ("meetings",)
S("m-zoom", "zoom", "Zoom Meeting", who=M, truth="meeting", text="Zoom Meeting. Weekly standup. Participants 8. Mute. Stop Video. Share Screen. Chat.")
S("m-meet", "chrome", "Meet - abc-defg-hij", url="https://meet.google.com/abc-defg-hij", who=M, truth="meeting", text="Meet. abc-defg-hij. Priya, Ravi, Ana, You. Turn off microphone. Turn off camera. Present now. Leave call.")
S("m-meet-listen", "chrome", "Meet - xyz-wvut-rst", url="https://meet.google.com/xyz-wvut-rst", who=M, truth="meeting",
  text="Meet. xyz-wvut-rst. All-hands. 124 people. Microphone off. Camera off. Raise hand. Captions.", note="listen-only: no live mic or camera, so the sense layer sees no call")
S("m-teams", "teams", "Quarterly review | Microsoft Teams", who=M, truth="meeting", text="Quarterly review. Microsoft Teams. Leave. Camera. Mic. Share. People 11. Chat.")
S("m-slack-huddle", "slack", "Huddle with Ana - Slack", who=M, truth="meeting", text="Huddle with Ana. Mute. Video. Share screen. Leave huddle.")
S("m-notion-notes", "notion", "Standup notes - Notion", who=M, truth="meeting", text="Standup notes. Attendees. Ravi, Priya, Ana. Updates. Ravi: finished the migration. Action items.")
S("m-gcal", "chrome", "Google Calendar - Week of 29 September 2026", url="https://calendar.google.com/calendar/u/0/r/week", who=M, text="Calendar. Week of Sep 29. 10:00 Standup. 11:00 Design review. 14:00 1:1 with Priya. 16:00 Quarterly review.")
S("m-gmail", "chrome", "Inbox (12) - charles@acme.example - Gmail", url="https://mail.google.com/mail/u/0/#inbox", who=M, text="Inbox. Priya: agenda for tomorrow. Ravi: notes from the call. Ana: deck v3. Invitation: Quarterly review.")

# ───────────── Dictation ─────────────
Dc = ("dictation",)
S("dict-notes", "notes", "Meeting recap", who=Dc, text="Meeting recap. Today we agreed to move the launch to the 14th. Ravi will own the migration and Ana will finish the onboarding copy. Open question: do we need legal review for the terms page.")
S("dict-docs", "chrome", "Launch plan - Google Docs", url="https://docs.google.com/document/d/1dict/edit", who=Dc, text="Launch plan. Goals. Ship the beta to fifty friends by the fourteenth. Success looks like seven day retention above forty percent.")
S("dict-wispr", "wispr", "Wispr Flow", who=Dc, truth="neutral", text="Wispr Flow. Listening. Hold fn to dictate.")
S("dict-medium", "chrome", "New story - Medium", url="https://medium.com/new-story", who=Dc, text="New story. Title. Tell your story... What I learned after a year of building alone. Publish. Draft saved.")
S("dict-substack", "chrome", "Untitled - Substack", url="https://substack.com/publish/post/17234", who=Dc, text="Untitled. Substack. Write a title. Start writing. This week I want to talk about why small teams ship faster. Save draft. Continue.")
S("dict-word", "word", "Cover letter.docx", who=Dc, text="Cover letter. Dear hiring manager, I am writing to apply for the senior product designer role at Orbit.")

# ───────────── Research that looks like browsing (a product manager) ─────────────
X = ("research",)
S("x-stripe-pricing", "chrome", "Pricing & Fees | Stripe", url="https://stripe.com/pricing", who=X, text="Pricing and fees. Pay as you go. 2.9% + 30c per successful card charge. Stripe Billing 0.7% of billing volume. Radar for fraud teams. Volume discounts.")
S("x-g2", "chrome", "Intercom Reviews 2025 | G2", url="https://www.g2.com/products/intercom/reviews", who=X, text="Intercom reviews. 4.5 out of 5. 3,100 reviews. What users like: shared inbox, bots. What users dislike: price jumps. Compare with Zendesk.")
S("x-linkedin-profile", "chrome", "Priya Nair - Head of Product - Orbit | LinkedIn", url="https://www.linkedin.com/in/priya-nair-product/", who=X,
  text="Priya Nair. Head of Product at Orbit. Bengaluru. 500+ connections. About: building customer feedback tools. Experience: Orbit 2022-present, Freshworks 2018-2022. Message. Connect.")
S("x-linkedin-job", "chrome", "Senior Product Designer - Orbit | LinkedIn", url="https://www.linkedin.com/jobs/view/3912345678/", who=X,
  text="Senior Product Designer. Orbit. Bengaluru (Hybrid). 5 applicants. About the job: you will own the design of our feedback inbox. Requirements: 5+ years, Figma, a portfolio. Easy Apply.")
S("x-reddit-saas", "chrome", "What do you use for customer feedback? : r/SaaS", url="https://www.reddit.com/r/SaaS/comments/1ab2cd/what_do_you_use_for_customer_feedback/", who=X,
  text="r/SaaS. What do you use for customer feedback? We are 12 people and drowning in Intercom threads. Top comment: we moved to a simple board plus a weekly review. Another: Canny, but pricey.")
S("x-tweet", "chrome", "Lenny Rachitsky on X: 'The best onboarding is the one users never notice'", url="https://x.com/lennysan/status/1840000000000000000", who=X,
  text="Lenny Rachitsky. The best onboarding is the one users never notice. Here are 7 patterns from 40 products. 1.2K Reposts 4.8K Likes. Replies.")
S("x-yt-demo", "chrome", "Notion Calendar - Full Walkthrough 2025 - YouTube", url="https://www.youtube.com/watch?v=NotCalDemo", who=X,
  text="Notion Calendar. Full Walkthrough. SaaS Reviews. 98K views. We test scheduling, time zones, and Notion databases inside the calendar. Pricing at 12:40.")
S("x-techcrunch", "chrome", "Orbit raises $40M to rethink customer feedback | TechCrunch", url="https://techcrunch.com/2026/09/30/orbit-raises-40m-customer-feedback/", who=X,
  text="Orbit raises $40M to rethink customer feedback. Orbit, a Bengaluru startup, announced a $40M Series B led by Accel. The company says 2,400 teams use its inbox.")
S("x-amazon-desk", "chrome", "Flexispot E7 Standing Desk, Electric Height Adjustable - Amazon.in", url="https://www.amazon.in/dp/B09XYZ1234", who=X, truth="work",
  text="Flexispot E7 Standing Desk. 4.4 out of 5. 2,310 ratings. Rs 28,999. Free delivery. Dual motor. Memory preset. Add to Cart. Buy Now.",
  note="researching a desk for the office: shopping on its face")
S("x-producthunt", "chrome", "Orbit - Product Hunt", url="https://www.producthunt.com/posts/orbit-feedback", who=X, text="Orbit. Customer feedback inbox for small teams. 612 upvotes. Comments 48. Pricing: free for 3 seats. Alternatives: Canny, Featurebase.")

# ───────────── Real drifts: feeds, videos, shopping, news, games ─────────────
R = ("drifts",)
S("r-x-home", "chrome", "Home / X", url="https://x.com/home", who=R, truth="drift", text="Home. For you. Following. What is happening. Trending. Post. Reply. Repost. Like.")
S("r-x-status", "chrome", "Elon Musk on X: 'Starship flight 12 next week'", url="https://x.com/elonmusk/status/1841111111111111111", who=R, truth="drift",
  text="Elon Musk. Starship flight 12 next week. 41K Reposts 512K Likes 9.8M Views. Replies. Trending in India.")
S("r-yt-home", "chrome", "YouTube", url="https://www.youtube.com/", who=R, truth="drift", text="YouTube. Recommended. Trending. Music. Gaming. Subscriptions.")
S("r-yt-gaming", "chrome", "I Beat the HARDEST Elden Ring Boss With a Guitar - YouTube", url="https://www.youtube.com/watch?v=GuitarBoss1", who=R, truth="drift",
  text="I Beat the HARDEST Elden Ring Boss With a Guitar. Shadowfalls. 3.1M views. Comments 18,402. Up next: 10 BANNED toys, Minecraft but every block is random.")
S("r-yt-music", "chrome", "Coldplay - Yellow (Official Video) - YouTube", url="https://www.youtube.com/watch?v=yellowCP", who=R, truth="drift", text="Coldplay - Yellow. Official Video. 1.1B views. Comments 410K. Up next: Fix You. Viva la Vida.")
S("r-yt-shorts", "chrome", "YouTube Shorts", url="https://www.youtube.com/shorts/abc123", who=R, truth="drift", text="Shorts. Cat opens a door. 3.2M. Like. Dislike. Comments. Share.")
S("r-netflix", "chrome", "Netflix", url="https://www.netflix.com/browse", who=R, truth="drift", text="Netflix. Home. TV Shows. Movies. Continue Watching. Trending Now. Because you watched Dark.")
S("r-prime", "chrome", "Amazon.com: Watch The Boys | Prime Video", url="https://www.primevideo.com/detail/0ABC", who=R, truth="drift", text="The Boys. Prime Video. Watch now. Episodes. Season 4.")
S("r-ig-feed", "chrome", "Instagram", url="https://www.instagram.com/", who=R, truth="drift", text="Instagram. Home. Stories. Suggested posts. Reels. Liked by friends.")
S("r-ig-reel", "chrome", "Instagram reel", url="https://www.instagram.com/reels/Cxyz/", who=R, truth="drift", text="Reels. Dance trend. 2.3M likes. Comment. Share.")
S("r-linkedin-feed", "chrome", "Feed | LinkedIn", url="https://www.linkedin.com/feed/", who=R, truth="drift", text="Feed. Start a post. Priya Nair likes this. 7 hacks to 10x your pipeline. Celebrate a promotion. Promoted.")
S("r-fb", "chrome", "Facebook", url="https://www.facebook.com/", who=R, truth="drift", text="Facebook. News Feed. Stories. Suggested for you. Marketplace. Groups.")
S("r-reddit-front", "chrome", "Reddit - Dive into anything", url="https://www.reddit.com/", who=R, truth="drift", text="Reddit. Home. Popular. r/funny r/pics r/gaming. Upvote. Comments.")
S("r-reddit-funny", "chrome", "My cat discovered the vacuum cleaner : r/funny", url="https://www.reddit.com/r/funny/comments/1k9z8/my_cat_discovered_the_vacuum_cleaner/", who=R, truth="drift",
  text="r/funny. My cat discovered the vacuum cleaner. 18.2k upvotes. 612 comments. Top: he looks like a tiny disappointed landlord.")
S("r-hn-front", "chrome", "Hacker News", url="https://news.ycombinator.com/", who=R, truth="drift", text="Hacker News. new | past | comments | ask | show | jobs. 1. A tiny database 2. Ask HN")
S("r-amazon-home", "chrome", "Amazon.in: Online Shopping India", url="https://www.amazon.in/", who=R, truth="drift", text="Amazon.in. Deals of the day. Best sellers. Mobiles. Fashion. Electronics. Today's deals.")
S("r-amazon-product", "chrome", "Sony WH-1000XM5 Wireless Headphones - Amazon.in", url="https://www.amazon.in/dp/B09XS7JWHH", who=R, truth="drift",
  text="Sony WH-1000XM5 Wireless Noise Cancelling Headphones. 4.5 out of 5. 8,214 ratings. Rs 26,990. 23% off. Add to Cart. Buy Now. Customers also viewed.")
S("r-espn", "chrome", "NBA Scoreboard - ESPN", url="https://www.espn.com/nba/scoreboard", who=R, truth="drift", text="NBA Scoreboard. Live. Lakers 102 Celtics 99 4th 2:14. Warriors vs Suns 8:00 PM. Top headlines.")
S("r-cricbuzz", "chrome", "Live Cricket Score - Cricbuzz", url="https://www.cricbuzz.com/live-cricket-scores/89021", who=R, truth="drift", text="India vs Australia. 3rd T20. India 168/4 (17.2). Live score. Commentary. Scorecard.")
S("r-bbc-front", "chrome", "BBC News - Home", url="https://www.bbc.com/news", who=R, truth="drift", text="BBC News. Home. Top stories. Storm hits east coast. Markets fall.")
S("r-cnn-article", "chrome", "Senate passes spending bill after marathon session | CNN Politics", url="https://edition.cnn.com/2026/10/03/politics/senate-spending-bill/index.html", who=R, truth="drift",
  text="Senate passes spending bill after marathon session. The Senate voted 62 to 38 early Saturday to avert a shutdown. Analysis: what the deal means for the midterms. Related video.")
S("r-toi-front", "chrome", "Times of India: Latest News", url="https://timesofindia.indiatimes.com/", who=R, truth="drift", text="Times of India. Latest news. India. World. Cricket. Entertainment. Top stories.")
S("r-buzzfeed", "chrome", "25 Celebrity Couples Who Looked Totally Different Before They Were Famous | BuzzFeed", url="https://www.buzzfeed.com/quiz/celebrity-couples-before-fame", who=R, truth="drift",
  text="25 Celebrity Couples Who Looked Totally Different Before They Were Famous. Posted on Oct 3. Number 14 will shock you. Share on Facebook. Comments 31.")
S("r-wordle", "chrome", "Wordle - The New York Times", url="https://www.nytimes.com/games/wordle/index.html", who=R, truth="drift", text="Wordle. Q W E R T Y U I O P. Enter. Guess 3 of 6. How to play. Statistics.")
S("r-chess", "chrome", "Play Chess Online - Chess.com", url="https://www.chess.com/play/online", who=R, truth="drift", text="Play Chess Online. Rapid 10 min. You 1215. Opponent 1224. Move 14. Resign. Draw.")
S("r-twitch", "chrome", "xQc - Twitch", url="https://www.twitch.tv/xqc", who=R, truth="drift", text="xQc. Twitch. Live. 41,203 viewers. Chat. Follow. Subscribe. Just Chatting.")
S("r-steam", "steam", "Steam", who=R, truth="drift", text="Steam. Store. Library. Community. Counter-Strike 2. Hades II. Play. Friends online 7.")
S("r-minecraft", "minecraft", "Minecraft Launcher", who=R, truth="drift", text="Minecraft Launcher. Play. Installations. Skins. Java Edition 1.21.")
S("r-spotify-web", "chrome", "Spotify - Web Player", url="https://open.spotify.com/playlist/37i9dQ", who=R, truth="drift", text="Spotify. Web Player. Your Library. Today's Top Hits. Play. Shuffle.")
S("r-whatsapp-friends", "whatsapp", "WhatsApp", who=R, truth="drift",
  text="Weekend crew. Arun: goa or pondy this weekend? Meera: pondy!! beaches and cafes. Arun: booking the bus tonight then. Charles: count me in, which cafe first? Meera: the french one near the promenade")
S("r-discord-memes", "discord", "#memes | Gaming Hangout - Discord", who=R, truth="drift", text="Gaming Hangout. #memes. sam: when the boss has 3 phases. kit: me after 5 hours of ranked. pat: lol")

# ───────────── Utilities and the locked screen ─────────────
U = ("all",)
S("u-login", "login", "loginwindow", who=U, truth="away", text="")
S("u-finder", "finder", "Documents", who=U, truth="neutral", text="Documents. Projects. Invoices. Taxes 2026.")


# ───────────── The goal each work screen belongs to, and the bucket Moku files it under ─────────────
# What the labeling questions answer in the QA brain (the focus pipeline only asks Jev for the state; threads and buckets
# are Jev's and Luna's other jobs, which these tests don't measure): Your day's grouping is judged on these.
TASKS = {
    "writing the printing-press essay": ("building", "w-docs w-pages w-hemingway w-thesaurus w-spotify"),
    "researching the printing press": ("learning", "w-notion w-wiki w-search w-cambridge w-nyt w-yt-lecture w-reddit-ask w-substack w-preview w-finder"),
    "answering the editors": ("communicating", "w-gmail w-slack"),
    "designing the Ember brand": ("building", "d-figma d-ps d-sketch d-ai d-blender d-canva"),
    "collecting design references": ("learning", "d-pinterest d-dribbble d-dribbble-home d-behance d-awwwards d-arena d-gfonts d-coolors d-yt-tut d-ig-studio"),
    "design crit with the team": ("communicating", "d-slack"),
    "building the rate limiter": ("building", "c-cursor c-vscode c-xcode c-term c-iterm c-warp c-alacritty c-androidstudio c-obsidian c-gh-pr c-gh-actions "
        "c-so c-mdn c-pkggo c-localhost c-sentry c-yt-talk c-medium c-leetcode c-hn-item c-reddit-golang c-claude c-claudeweb c-linear c-postman "
        "c-tableplus c-docker"),
    "backend chat": ("communicating", "c-slack"),
    "studying organic chemistry": ("learning", "s-pdfexpert s-zotero s-anki s-canvas s-yt-crash s-quizlet s-scholar s-preview-pdf s-word s-overleaf "
        "s-discord-study s-notes s-chatgpt s-zoom-lecture"),
    "CS101 recursion": ("learning", "s-obsidian s-coursera s-yt-mit s-gdocs s-wolfram s-whatsapp-class"),
    "meetings": ("communicating", "m-zoom m-meet m-meet-listen m-teams m-slack-huddle m-notion-notes m-gcal m-gmail"),
    "writing the launch plan": ("building", "dict-notes dict-docs dict-medium dict-substack dict-wispr dict-word"),
    "competitor research": ("working", "x-stripe-pricing x-g2 x-producthunt x-yt-demo x-tweet x-techcrunch x-reddit-saas x-amazon-desk"),
    "hiring a designer": ("working", "x-linkedin-profile x-linkedin-job"),
}
DRIFT_BUCKETS = {
    "scrolling": "w-x-home w-ig-feed r-x-home r-x-status r-ig-feed r-ig-reel r-linkedin-feed r-fb",
    "watching": "r-yt-home r-yt-gaming r-yt-music r-yt-shorts r-netflix r-prime r-twitch r-spotify-web d-yt-home",
    "reading": "w-bbc-front w-bbc-article r-reddit-front r-reddit-funny r-hn-front c-hn-front r-espn r-cricbuzz r-bbc-front r-cnn-article r-toi-front r-buzzfeed",
    "shopping": "r-amazon-home r-amazon-product",
    "chatting": "r-whatsapp-friends r-discord-memes",
    "playing": "r-wordle r-chess r-steam r-minecraft",
}
for task, (bucket, ids) in TASKS.items():
    for sid in ids.split():
        for s in screens:
            if s["id"] == sid:
                s["task"], s["bucket"] = task, bucket
for bucket, ids in DRIFT_BUCKETS.items():
    for sid in ids.split():
        for s in screens:
            if s["id"] == sid:
                s["bucket"] = bucket

if __name__ == "__main__":
    ids = [s["id"] for s in screens]
    assert len(ids) == len(set(ids)), "duplicate ids"
    for s in screens:
        assert s["truth"] != "work" or "task" in s, "no task for " + s["id"]
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(screens, ensure_ascii=False, indent=1) + "\n")
    print(f"{len(screens)} screens -> {OUT}")
