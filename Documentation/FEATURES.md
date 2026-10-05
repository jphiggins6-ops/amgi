# Features

What Amgi does today. For how it is put together, see [ARCHITECTURE.md](ARCHITECTURE.md).

## Studying

- **FSRS scheduling** — the official Rust FSRS engine, not a reimplementation. Ratings, intervals, and review history are computed by the same code as Anki Desktop.
- **Review session** — Again/Hard/Good/Easy with the next interval printed on every button, session progress, rating toast with auto-advance, native typed-answer field, tap-to-play audio, undo, and a pencil in the top bar that opens the card's note for editing in one tap.
- **Time left** — under the progress bar, "About 12 min left · done around 3:42 PM", worked out from how fast you've answered so far this session and how many cards are left; when studying a deck, with an extra turn for each new card's learning step and for the repeats your misses bring back. Hide it from the ⋯ menu while reviewing, or Settings → Review → Progress.
- **Today's minimum: Reviews and New** — the Library's top card has one big button for reviews and one for new cards. Each shows what's left of a total that's fixed for the day, "120 of 300": Reviews counts every card that was due today and has no flag and isn't in deck "p", New counts today's new cards from every deck but "p", within each deck's daily limit. Each round shows every card once, shuffled across decks; a card you miss doesn't come back in the round, so the count only goes down. Leave part way and you pick up where you left off. Finishing a round shows "Done for today" (or which half is left) for a moment and goes back to the Library, and once both are done the top card turns green: today's minimum is met. After that, Reviews offers **Due again**, a round of the cards seen today that are due again, each once, as often as you like. The numbers come from Anki's own searches (answered today, first learned today), so they hold across restarts and other devices and reset with Anki's day. New cards learned this way are charged to their home decks' daily limits when the session closes, as studying the deck itself would.
- **End-of-day summary** — when the round that finishes today's minimum closes, a sheet shows time studied, how much you got right, and your 5 hardest cards: the ones you missed today that you've forgotten most often. They start ticked; one tap flags them red for the Graveyard. Reopen it any time that day from "Today's summary" on the green top card.
- **Today widget** — home screen (small, medium) and lock screen (circle, rectangle, inline): "128 left", Reviews "120 of 300", New "8 of 20", turning green with a seal once today's minimum is done. Updated whenever the Library loads, and when the app is left part way through a Reviews or New round; after Anki's day rolls over it shows "New day" with an estimate until the app is opened: reviews from the forecast, and as many new cards as today brought.
- **Number on the app icon, turning green** — the red badge on Amgi's icon shows what's left of today's minimum, the widget's number: Reviews + New by default, or Reviews only, or off (Settings → Review → App Icon). It's set whenever the Library loads and when the app is left mid-round. While the app stays closed it moves on by itself at each of the next seven rollovers, to the same estimate as the widget, using badge-only local notifications that show nothing on screen; iOS asks once for the notifications permission (badges only). Once everything it counts is done, the stars turn green: an alternate icon, `AppIconDone` in the asset catalog, listed in `project.yml` under `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES` ("Turn green when done" switches it off). iOS changes an app's icon only while it's open and shows an alert each time, so the change waits until nothing else is open, and until the end-of-day summary has been closed; the blue stars come back the first time the app is opened on a new day.
- **Hands-free mode** — for walking or a commute: ⋯ → Hands-Free Mode (or a tap, swipe or shake set to it) reads each card aloud and takes answers by voice. Say "show" to turn the card over and hear just the answer (on a cloze, only the revealed cloze; the Extra field is never read), then "again", "hard", "good" or "easy"; or rate straight away and the card is rated without the answer being read. "Repeat", "undo" and "stop" work any time, and taps still work. Korean, Japanese and Chinese text gets a voice for that language. Hidden hint content, pictures and the question above the answer line aren't read. With headphones you can talk over the reading. Speech recognition runs on the phone when it can, and it keeps going with the screen locked (background audio). Reading speed is in Settings → Review → Hands-Free.
- **Explain** — once the answer is showing, an Explain button above the rating bar (also in ⋯ and as a tap/swipe/shake action) asks OpenAI why the answer is right, with the key context, using the Graveyard's key and model. Ask follow-up questions in the same sheet.
- **Every due card before repeats** — on by default when studying a deck: a card you miss, or one still in learning, waits until every other due card has been shown once. Only the order changes; the engine still schedules each answer when you give it. Settings → Review → Card Order switches back to Anki's usual order.
- **Taps, swipes and shake** — nine tap areas on the card, four swipes, and a shake of the phone, each set to show the answer, rate, undo, replay audio, flag, edit the note, or capture a visual mnemonic (Settings → Review Behavior → Taps, Swipes & Shake). A rating on the question side shows the answer instead; taps on links, audio buttons, and looked-up words behave as before, and a swipe that scrolls a long card counts as scrolling.
- **Keyboard control** — rate, reveal, and undo from a hardware keyboard, with the typed-answer field staying up across the reveal.
- **Dual card rendering** — the Rust template engine renders cards exactly like desktop clients. Simple cards are auto-detected and drawn by a native SwiftUI renderer; complex cards fall back to a sandboxed WebKit host. ⋯ → Card Rendering shows which path the card is on ("HTML · auto · Cloze") and pins the render mode, globally or per template; it used to be a bar above every card. Turning a card over keeps its text where it was: the answer starts where the question sat on screen (rather than being centred again, which moved the text up by half of whatever the answer adds), what it adds runs on below, and the page scrolls if it has to; it scrolls by itself only when the answer line would be below the screen. A note's Extra field (the first field with "extra" in its name) gets a blank line's gap above it on the answer side when the template leaves none: the app marks where the field's HTML begins in the rendered answer, and the card page measures the gap there.
- **MathJax and audio** — formula rendering and card audio playback in both renderers.
- **Today view** — an aggregate "due now" screen across every deck, with an up-next queue ordered by workload.
- **Graveyard** — a tab for every card flagged red or orange, however overdue, kept out of the Reviews button until it's dealt with. For each: ask an AI (OpenAI, same key as the pictures) whether it's right and have it propose a fix you can apply in one tap, add a diagram or mnemonic picture to its Extra field, edit it by hand, mark it fixed, or delete it. Marking it fixed starts the card over as a new card, so the fixed version is learned from scratch: Anki's Reset with its original place among the new cards restored where Anki knows it, and its review and lapse counts cleared so the problem-card rule doesn't flag it straight back; then the flag is cleared. Settings moved from the tab bar to the Library's More menu to make room. Cards you keep forgetting arrive on their own: once a card has been forgotten 5 times (Settings → Review → Graveyard: off, or 3 to 10), missing it again flags it orange as the session closes, and a button there flags the cards already past that.
- **Visual mnemonics** (experimental) — tap ✨ while reviewing to save an idea for a picture onto the card, then carry on. Later, from Library → Mnemonics, edit each description, generate a draft, and approve it into the card's Extra field (or Back Extra / Back) or discard it. Nothing reaches the card until you approve. Ideas are stored inside the note, so they sync like any other edit. Pictures come from OpenAI's image API once you save an API key (Mnemonics → ⚙︎); until then drafts are free placeholder squares. The key is kept in the Keychain, drafts are kept on the device until approved, and pictures are stored as 768 px JPEGs.

## Decks

- **Hierarchical deck tree** — recursive expand/collapse with new/learning/review count badges on every node, as a list or a grid.
- **Deck detail** — per-deck counts, retention, average cards/day, mature card count, and subdeck breakdown.
- **Per-deck study options** — FSRS weights editor with optimizer and simulator, preset CRUD, Easy Days, bury rules, review timer, auto-advance.
- **Custom study and filtered decks** — extend today's new-card and review limits per deck, and rebuild or empty a filtered deck to return its cards to their home decks.
- **Filtered deck presets** — save named searches (query, card limit, gather order, reschedule flag) and build any selection of them into filtered decks in one tap. Presets are app-local and per profile; the decks they build are ordinary Anki filtered decks and sync like any other.
- **Import** — `.apkg` and `.colpkg` import, including from the iOS share sheet, with progress shown while it runs. Text files with one note per line (`.tsv`, `.csv`, `.txt`) go through Anki's own CSV importer: a sheet shows the first lines and lets you choose the separator (a `.tsv` starts on Tab), whether fields hold HTML, the note type, the deck, which column fills each field, a tags column, and what happens to notes already there (update, leave, or add again); file headers like `#separator:` and `#deck:` are honoured. Library ⋯ → Import Deck or Text File….

## Notes

- **Browser** — search the whole collection with Anki search syntax, deck filter chips (a top-level deck includes its subdecks), tag chips, sorting, and lazy-loaded results.
- **Editor** — rich field editing with accurate field names pulled from the Rust notetype RPC; multi-select for batch operations. Paste (top left) adds whatever you've copied, text or pictures, to the end of the Extra field (or Back Extra / Back / the last field), with no "Allow Paste?" prompt. Pictures are stored as media named for their content, as Anki names pastes, at most 1600 px and as JPEGs unless they have see-through parts.
- **Tags** — batch tagging from a selection, plus collection-wide tag management.
- **Duplicates** — find notes that share a first field, which is the question Anki's `dupe:` operator does not answer.
- **Image occlusion** — create and edit occlusion notes with rectangle, ellipse, polygon, and text masks, with reviewer parity with upstream Anki.
- **Card templates** — a full template editor with front/back/styling source editing, live preview, validation, and notetype field management.

## Reader

- **EPUB reader** — read books chapter by chapter with native paging, vertical writing mode, and Latin/CJK auto-detection.
- **Offline dictionary lookup** — tap any word for a Yomitan-compatible lookup, with chained popups, search history, and per-dictionary collapsed memory.
- **Text-to-speech** — a speak button with language-aware voice selection.
- **Bundled Korean fonts** — Sarasa Mono K, Nanum Myeongjo, Nanum Gothic.
- **Progress sync** — reading position travels with the collection across devices.

## Sync and accounts

- **Any compatible sync server** — AnkiWeb or self-hosted: login, incremental sync, full upload/download, media sync, and bidirectional review sync.
- **Safe sync merge** — when local and server collections diverge, merge them (keeping cards from both sides) instead of being forced to overwrite one. Destructive choices require explicit confirmation.
- **Multi-profile accounts** — isolated collections per profile, a fast picker in the Library toolbar, and per-profile sync credentials and review history.
- **Offline-first** — everything works offline; sync when you have a connection.

## Statistics

- **Dashboard** — all-time and windowed summaries (reviewed, time, young, mature, new, relearn), future-due forecast with backlog toggle, stacked review history, and card count breakdown.
- **Review heatmap** — full-year contribution-style heatmap that auto-scrolls to today, with a streak counter.
- **Streak card** — current streak against the same point last month, at the top of the dashboard.
- **VoiceOver** — every chart is readable as an audio summary, not an unlabelled image.
- **Scoping** — every graph can be scoped to the whole collection or one deck, over Today / 7 days / 1 month / 3 months / 1 year / all time.

## Beyond the phone

- **Home-screen widgets** — small, medium, and large families driven by a precomputed forecast timeline, configurable per deck through AppIntents, with no background refresh required.
- **Apple Watch app** — deck list, card review with audio playback, stats, and sync, with the Anki engine running on-device.
- **Shortcuts and Siri** — study a deck, sync the collection, or ask how many cards are due, from Shortcuts, Spotlight, or by voice.

## Maintenance and appearance

- **Guided first run** — a four-step welcome tour before the sync choice, skippable at any point.
- **Multi-theme system** — Vivid and Muted palettes with Light/Dark/Follow-System, shared with the widgets through an App Group. Every bundled palette meets WCAG AA contrast, and a test keeps it that way.
- **Database tools** — check database, find empty cards, media check, and backup management.

## Under the hood

- **Swift 6.2 strict concurrency** — language mode v6, fully actor-isolated, `Sendable` throughout.
- **Rust owns the data** — Swift never touches SQLite. Every read and write goes through the engine's RPC seam.
