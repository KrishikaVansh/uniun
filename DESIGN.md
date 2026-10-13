# UNIUN — Redesign Design System & Screen Spec

> Single source of truth for implementing the redesign. Pairs the **design-system foundations**
> (tokens, components) with the **screen-by-screen spec** and the **decisions** made while
> redesigning. Read alongside `CLAUDE.md` (architecture) and the interactive gallery.

**Where things live**
- **Design system** (tokens · components · brand guide): [`UNIUNDesignSystem/`](UNIUNDesignSystem/) — link one file, `UNIUNDesignSystem/styles.css`, to get every token + webfont.
- **Interactive gallery** (40 click-through screens, phone frame): [`UNIUNDesignSystem/ui_kits/uniun_app/index.html`](UNIUNDesignSystem/ui_kits/uniun_app/index.html). One self-registering JSX file per screen in `screens/`.
- **This doc**: the implementation reference — what each screen is, how it behaves, and which production widget it maps to.

**Run the gallery**
```bash
cd UNIUNDesignSystem && python3 -m http.server 8765
# open http://localhost:8765/ui_kits/uniun_app/index.html
```

---

## 0. Product context (one paragraph)

UNIUN is a decentralized, offline-first social **and** knowledge network on Nostr (Flutter, iOS + Android, light + dark theme). One primitive — the **Note** (a Nostr Kind 1 event) — powers a feed (**Vishnu**), a knowledge-graph composer (**Brahma**), an on-device AI (**Shiv**), plus public **Channels**, MLS-encrypted **private channels**, and **DMs**. A **Manas** is a user-named subset of notes used to scope Shiv. Brand voice: calm, technical, sovereign (closer to Signal / Linear / Obsidian than to Twitter). **Notes are forever — there is no delete anywhere.**

---

## 1. Foundations

All values are CSS custom properties in `UNIUNDesignSystem/tokens/*` and map 1:1 to the Flutter theme (`lib/core/theme/app_theme.dart`). px sizes are chosen to map directly to Flutter logical pixels.

### 1.1 Color — single accent

One vivid blue carries **every** primary action, active state, link, highlight and selection. There is **no second brand color**.

| Token | Value | Use |
|---|---|---|
| `--primary` | `#0075F2` | the one accent |
| `--primary-hover` | `#0066D6` | hover/darker |
| `--primary-pressed` | `#005AB6` | pressed/deep |
| `--primary-container` | `#1672DF` | gradient end (onboarding only) |
| `--primary-tint` | `#EAF3FE` | 8% wash — active tabs, chips, icon squares |
| `--primary-tint-strong` | `#D4E7FD` | chip borders / stronger tint |
| `--on-primary` | `#FFFFFF` | text/icon on primary |

**Neutrals** carry a faint cool (slate-blue) undertone: `--neutral-0` `#FFFFFF` → `--neutral-25` `#FAFBFD` (scaffold) → `--neutral-50` `#F4F7FB` → `100` `#EBEFF5` → `200` `#DEE4EC` → `300` `#CBD3DF` → `400` `#A7B0BE` → `500` `#6B7480` → `600` `#4A515C` → `700`–`900`.

**Surfaces:** `--surface` `#FFFFFF` (cards/sheets) · `--surface-bg` `#FAFBFD` (scaffold) · `--surface-low` `#F4F7FB` (input rest, composer) · `--surface-container` `#EBEFF5` · `--surface-container-high` `#DEE4EC`.

**Text:** `--text-primary` `#191C1E` · `--text-body` `#1E293B` (note/chat body) · `--text-secondary` `#414753` (meta/labels) · `--text-muted` `#6B7480` (timestamps/captions) · `--text-disabled` `#A7B0BE`.

**Borders:** `--border-subtle` `#EEF2F7` (note/list dividers) · `--border` `#DEE4EC` (default outline) · `--border-strong` `#C3CCD8`.

**Semantic:** `--success` `#059669` · `--warning` `#D97706` · `--error` `#BA1A1A` · `--reaction-like` `#EF4444` (heart). `--glass-fill` `rgba(255,255,255,.72)` · `--scrim` `rgba(21,24,28,.40)`.

**Knowledge-graph node colors — DECISION (changed):** production source-coding is blue/green/orange, but the redesigned Brahma graph uses a **mono-blue** palette so the graph stays single-accent:
- Saved → `#0075F2` · Own → `#6FB0F8` (blue-300) · Draft → `#00458E` (blue-800) · topic/tag → `#A7B0BE`.
- (The old `--graph-own` green `#059669` / `--graph-draft` orange `#D97706` are still used as the **Draft pill** color in compose/Nataraj, and as semantic success/warning — but **not** in the graph.)

### 1.2 Type

- `--font-display` **Newsreader** (humanist serif) — brand/display moments ONLY (onboarding headlines, deity names). Used sparingly.
- `--font-sans` **Geist** — all product UI and body.
- `--font-mono` **Geist Mono** — every cryptographic identifier (npub, nsec, event id, hash, group id, relay url).

Scale (px): `display 34 · h1 28 · h2 22 · h3 18 · lg 17 (composer) · base 15 (note/UI) · sm 14 · xs 12 (meta) · 2xs 10 (tab labels, eyebrows)`. Weights 400–800. Line-height `body 1.55` (note/chat), `tight 1.15` (display). Tracking `tight -0.02em` (display), `eyebrow 0.14em` (uppercase labels). Note body = 15px / 1.55.

### 1.3 Spacing / radius / shadow / motion

- **Spacing:** 4px grid (`--space-1..16` = 4..64). Screen gutter 16. Content cap 640 centered. Touch ≥ 44. App bar 56, floating nav 64. Avatars 32 / 40 / 56.
- **Radius:** inputs & default cards `--radius-md` 12 · sheets/large cards `--radius-lg` 16 · `--radius-xl` 20 · bottom-sheet top `--radius-2xl` 28 · chips/pills/avatars/FAB/nav `--radius-full`.
- **Shadow:** most elevation `--shadow-sm`. Two blue-tinted exceptions: `--shadow-nav` (floating nav) and `--shadow-primary` (primary CTAs). `--blur-glass` 12px.
- **Motion:** `--dur-base` 200ms (`--ease-standard`) for tab swaps/hover/color; `--dur-fast` 120ms; `--dur-slow` 320ms. Press = small scale-down on big CTAs. No bounce, no looping decoration.

### 1.4 Iconography

Two registers: **(1) brand glyphs** — `DeityGlyph` for Vishnu / Brahma / Shiv (the three nav icons, flame/teardrop motif) + the UNIUN swastika mark (`assets/logo/`). **(2) UI icons** — Google **Material Symbols Rounded** only (`<span class="material-symbols-rounded">name</span>`, weight ~400, opsz 24). No emoji in chrome (emoji allowed only inside user-generated note/message content). No one-off SVGs except simple graph lines.

### 1.5 Non-negotiables (NEVER violate)

1. **No *network* delete — local removal is allowed.** Notes are forever on the network ("Feed Freedom"): UNIUN never publishes a NIP-09 Kind 5 deletion, so nothing a user does erases a note from the relay or anyone else's device. The primary verbs are save, follow, reference. The note overflow menu (⋮) *does* offer **"Delete note,"** which is a purely **local** action — it writes a `DeletedNoteModel` tombstone and removes the event from this device's Isar (note + feed projection + relation edges). The tombstone is honoured by the Gateway (the id is excluded from REQ subscriptions), so the note won't re-sync back to this device; the event itself is untouched on Nostr. Other destructive-sounding verbs (leaving a channel, clearing a draft, declining a join request, blocking a user) are likewise local-only and fine.
2. **One accent** `var(--primary)`. Only other saturated colors: semantic state + the mono-blue graph shades.
3. **Type:** Newsreader for brand moments only; Geist for UI; Geist Mono for crypto identifiers.
4. **Casing:** sentence case everywhere; UPPERCASE + wide tracking only for tab labels and small eyebrow/section labels (`SectionLabel`). Wordmark `UNIUN` is all-caps.
5. **Feed = flat** (white, no radius, single bottom hairline). Contained cards get radius + border + soft shadow.
6. **Active states = tint or pill,** never a heavy white-on-blue fill.

---

## 2. Components & patterns

### 2.1 Primitives (`UNIUNDesignSystem/components/`)

| Component | Key props | Notes |
|---|---|---|
| **Button** | `variant` (primary/secondary/ghost/tinted/danger), `size` (sm/md/lg), `icon`, `iconRight`, `full`, `disabled` | pill, brand blue, tinted lift |
| **IconButton** | `icon`, `size`=40, `iconSize`, `color`, `filled`, `badge` (alert dot), `label` | circular app-bar/action icon |
| **Chip** | `active` (filled primary), `tonal` (tint wash), `icon` | filter/topic/selectable pill |
| **Badge** | `count`, `dot`, `tone` (primary/activity/alert/neutral) | unread/activity |
| **Avatar** | `seed` (pubkey), `photoUrl`, `name`, `size`=40 | deterministic, initials fallback |
| **Card** | `padding`=16, `radius`, `dashed` (empty/preview), `hover` | contained surface (NOT feed notes) |
| **Input** | `value`, `multiline`, `rows`, `leadingIcon`, `trailing` | filled input/textarea |
| **SectionLabel** | `color`, `icon` | UPPERCASE wide-tracked eyebrow |
| **DeityGlyph** | `surface` (vishnu/brahma/shiv), `size`, `color` | brand glyph |
| **FloatingNav** | `active`, `onChange`, `vishnuBadge`, `shivActivity` | 3 surfaces; Brahma = raised center FAB. **Badge/activity-dot off by default in the redesign.** |
| **GraphNode** | `label`, `meta`, `source`, `variant`, `current` | knowledge-graph node |
| **NoteCard** | `author`, `time`, `source`, `content`, `image`, `hashtags`, `replies`, `references`, `saved`, `following`, `isOwn`, `onSave/onFollow/onShare/onReply` | the core content unit; flat hairline |
| **MessageBubble** | `from` (me/them/shiv), `time` | **only Shiv AI chat uses bubbles** |

### 2.2 Composed patterns (standardized in the redesign)

- **Rich composer (the "does-a-lot" composer)** — mirrors production `UniunComposer` (`lib/common/widgets/composer/uniun_composer.dart`). A `--surface-low` card (top radius 24): optional reply/reference/attachment rows, a text field, then a control row: **avatar (= Shiv/Manas switch)** · add-reference · add-media · markdown · … · send. Used in thread / channel / DM / private composers and Brahma compose.
- **Composer AI mode (composer-chat)** — tap the composer avatar → **Manas picker sheet** → the composer becomes an inline Shiv chat grounded in the surface + the picked Manas: Shiv-branded banner (auto_awesome + "Shiv · {Manas} · on-device" + ×), `MessageBubble`s, suggestion chips, and an input whose left avatar is the Manas switch + a model chip (Qwen3) + send. Works in every surface that has the composer (thread/channel/DM/private). Mirrors `lib/features/shiv/composer_chat/`.
- **Reference note (grey, action-less)** — a *small muted note*: avatar(30–38) + name·time (secondary) + faded content (`rgba(25,28,30,.55)`, 2–3 lines). Used for Thread references (on top of the root), Nataraj sources, and ReferencePicker rows. Mirrors `lib/common/widgets/note_card/reference_note_card.dart`.
- **List row** — avatar/icon-square + title + subtitle + trailing (Badge/count). Drawers, channel/DM lists.
- **Chat open position & unread** — applies to channel, private-channel and DM chats (all `NoteCard` feeds).
  - **Opens at your first unread note**, near the middle of the screen, with the read notes above it; with nothing unread it opens at the newest note, at the bottom. The position is fixed when the chat opens, so notes arriving later never move the view.
  - A **"New notes" divider** — a thin primary-tint line, a centered small primary label (`labelSmall`) and another line — sits directly above the first unread note. It stays for the life of the page.
  - **Jump-to-latest** — a round floating button (44px, surface fill, `--border-subtle`, soft shadow) bottom-right with a down chevron; it appears once you are away from the bottom and carries a **count badge** (primary fill) of unread notes, capped at "99+". Tapping it scrolls to the newest note.
  - **Marking read:** a note is read once at least half of it has been on screen (not when it scrolls away, so reading three and going back leaves the right count), and the whole chat is read when you reach the newest note — including when it opens already there and when a note arrives while you sit at the bottom. Nothing is marked while the list is still loading, while another page covers the chat, or while the app is in the background.
  - The drawer's count and the jump button's number are the same unread rows, so they move together.
- **Stat tile** — a white contained card (radius 16, 1px `--border`): a large tabular-figure value (24/800, colored by meaning) over a muted 12/600 label. Used in 2 × 2 grids on the Gana dashboard.
- **Outcome bar** — a 6px, fully rounded stacked bar showing how runs ended: `--success` (done) · `--error` (failed) · `--outline-variant` (skipped), widths by count; an empty muted track before the first run. Never animated, never more than one per card.
- **Settings group** — contained card, rows with hairline dividers, leading icon + label + chevron.
- **Bottom sheet** — scrim + sheet pinned to bottom (`--radius-2xl` top) + 36×4 grabber. Used for: Share, Manas pickers, Manas membership, private-channel pending requests.
- **Manas picker sheet** — "Chat with your notes / Scope to a Manas" → list: **All notes → Ask Brahma** + per-Manas rows (icon + name + note count) + selected check.
- **Knowledge graph** — light force-graph over a dot grid: **mono-blue filled circles** sized by connection count, label beneath, thin edges, glow on the focused node, a legend, a bottom search. Implementable with the app's `graphview ^1.5.1` (force layout + custom node widgets + edge paint; see `lib/features/brahma/graph/widgets/graph_canvas.dart`).

---

## 3. Screens (by surface)

40 screens in the gallery. Each below: **what it is → key decisions**. Sidebar label in *italics*.

### 3.1 Onboarding & identity
- *Splash* — brand mark + ambient blur, auto-advances.
- *Welcome* (`Onboarding.jsx`) — **mirrors production `welcome_page.dart`**: logo over a radial glow, gradient "UNIUN" wordmark, "Your decentralized **second brain**", and the **trimurti pillars** (Brahma · Vishnu · Shiv → Create / Reflect / Transform) in one faint-blue bordered card. CTAs: **Create Your Avatar** / **Restore Your Avatar** + "Learn how UNIUN works".
- *How it works* — 3-card intro carousel (Vishnu/Brahma/Shiv) with progress dots.
- *Avatar keys* (`CreateIdentity.jsx`) — **wording uses "Avatar," not "identity"**: eyebrow "Your avatar keys", "Your keys are your avatar.", npub (mono, copy) + nsec (masked, reveal), a back-up warning, "I've backed up my key", Continue.
- *Restore avatar* (`ImportIdentity.jsx`) — eyebrow "Restore your avatar"; paste nsec (mono) or scan QR.
- *About you* — profile setup: avatar picker, display name, nip05, about.

### 3.2 Vishnu — feed
- *Feed* (`VishnuFeed.jsx`) — flat `NoteCard` list. **Minimal header: menu · QR-scan · avatar** (no channel chips, no notification bell, no UNIUN wordmark). Tapping a note → Thread.
- *Spaces drawer* (`SpacesDrawer.jsx`) — left slide-in. Header (avatar + npub + settings) + **My QR code / Scan code** + **Search spaces…**. **Collapsible sections, ordered: Direct messages · Channels · Private channels · Followed notes · Saved notes**. Unread is a **count Badge** on DMs, channels, private channels and followed notes alike (a number, not a dot; no member counts). The count drops as notes are read.
- *Thread* (`Thread.jsx`) — **references on top → root note → flat replies** (no nesting). **In a followed note's thread** each reply can carry a one-line **unread mark** above its card: a bright dot + "New" when that reply is itself unread, a quiet dot + "New reply inside" when an unread reply sits further down, so the trail leads to it. A note is marked read only when its own thread opens, never by seeing its parent. Marks appear only for followed notes. References render as grey reference notes with a "Show N more references" expand past 2. **Composer doubles as Shiv chat:** the avatar (with a sparkle badge) → Manas picker → inline Shiv chat grounded in the thread.

### 3.3 Brahma — knowledge-graph workspace
> **DECISION:** Brahma is **not** a text editor — it is the graph workspace (`lib/features/brahma/graph/pages/graph_page.dart`).
- *Brahma · graph* (`KnowledgeGraph.jsx`) — the Brahma home: header **menu → Manas drawer** · "Brahma" · search; an "All notes ▾" scope chip; the **mono-blue circle graph**; a **compose FAB**. (Shiv's "Knowledge graph" link + the nav's Brahma button both land here.)
- *Manas drawer* (`BrahmaManasDrawer.jsx`) — mirrors `brahma_drawer.dart`: "Brahma · Your whole graph" entry + per-Manas tiles (icon · name · note count) that scope the graph + "New Manas" + "Search Manas…".
- *Compose note* (`BrahmaCompose.jsx`) — the note fills the page; **Manas membership chips + the rich control row dock at the bottom** (avatar · add-reference · add-media · markdown · count). No reference-graph preview.
- *Reference picker* (`ReferencePicker.jsx`) — rows are **thread-style reference notes**; filter chips (All / Saved / My notes / Drafts) use **mono-blue** dots; multi-select with a check.

### 3.4 Shiv — on-device AI
- *Shiv home* (`ShivHome.jsx`) — **decluttered**: hero "Ask anything about your notes…" card (with Manas scope chip) → Recent conversations (flat rows + See all) → a "Tools" 2-tile row (**Gana · Nataraj only** — the Knowledge-graph & AI-model tiles were removed; graph lives in Brahma, model in Settings).
- *Chat* (`ShivChat.jsx`) — Shiv-branded header (scope shown), `MessageBubble`s + suggestion chips, and the **Manas-view composer** (Manas-switch avatar + model chip + send + Manas picker). **Floating nav hides in chat.**
- *History* (`ShivHistory.jsx`) — conversation list, grouped by day. Row menu = Rename / Pin (no delete).
- *Branch tree* (`BranchTree.jsx`) — the parentId branch tree; active leaf highlighted; node action panel (View / Switch / Branch from here).
- *Gana · dashboard* (shipped in 3.1; replaces the old agent list and its gallery screen `GanaList.jsx`) — **the one Gana screen; there is no separate list page.** Centered "Dashboard" title, common back button, and a **New** pill (primary, stadium) in the app bar. The scaffold is `surfaceContainerLow` with 16px gutters and a single scrolling column:
  1. **Four stat tiles in a 2 × 2 grid** — *Active* (`on/total`, primary) · *Done* (success) · *Failed* (error when above zero, otherwise muted) · *Skipped* (muted). Each tile is a white card, radius 16, 1px `--border`, value 24/800 with tabular figures over a 12/600 label.
  2. **Needs attention** (only when a Gana's last run failed) — flat activity rows with the error in error color, up to three lines; tapping opens that Gana.
  3. **Your Ganas** — one contained card per Gana (radius 16, `--border`, no shadow): name 15/700 · success rate · on/off switch, then a **thin 6px outcome bar** (done / failed / skipped), then a wrapping line of *trigger* and *scope* (2 lines max each so it never overflows at 320px or 1.5× text), then the last run ("Succeeded · 2 min ago" or "Never run"). Tapping the card opens the detail page.
  4. **Recent activity** — the 10 newest runs across all Ganas as flat rows: a status dot, "Gana name · status", the time, and a one-line error for a failed run.
  5. A footnote that totals only count runs from this version on.
  - **Empty state:** a primary-tint circle with the agent glyph, a short "what a Gana is" line and a **New** button.
  - **Rules:** success rate = done ÷ (done + failed); skipped runs are left out (a Gana waiting for input skips a lot without failing). The page uses the same surfaces, borders, back button and l10n as the other Shiv screens.
- *Gana · detail* — the same configuration as a read-only summary (name, on/off, **scope**, input, output, trigger), lifetime done / failed / skipped with the same outcome bar, and the last 10 runs as **drop-downs**: a succeeded run opens to the note it published, a failed run to a plain-words reason (no identity / publish / network / model / other) with the raw error underneath, a skipped run to a sentence for its skip reason.
- *Gana · new / edit* (`GanaForm.jsx`, updated in 3.1) — a stack of contained cards on `surfaceContainerLow`: **Name** · **Task** (instruction) · **Knowledge** · **Connections** (Watch → which channel/DM/note/user; Publish to → Your feed / A channel / A private group / A DM, with a "which one" sub-picker; Model) · **Schedule** (trigger preset, interval, max outputs) · **Enabled**. The **Knowledge** card is a chip row of exactly one choice: **No knowledge** · **Brahma** (the default — the whole knowledge base) · one **Manas** from the list, plus a "Create Manas" chip. Returning from creating a Manas refreshes only the chip list; the unsaved draft is kept. When **Brahma** is picked together with a cloud model, a small error-colored line warns that the notes are sent to that model (pick a Manas or No knowledge to keep them on the device).
- *Nataraj* (`Nataraj.jsx`) — **swipe deck**. The card fills the screen and reads like a mini-thread: grey **source reference notes** (collapsed past 2 with a "Show N more" expand) → a centered **Shiv synthesis mark** → the **synthesized note** (rendered note-style, Draft pill). Actions: **Skip · Keep · Discuss · Shuffle**. No "Synthesized from" header, no side cues.
- *AI model* (`ModelSelect.jsx`) — on-device model list (Qwen3 0.6B / DeepSeek R1 / Gemma 4 E2B/E4B) with active / download / progress states.
- *Composer AI chat* (`ComposerChat.jsx`) — demonstrates the composer→Shiv chat in a channel context (see pattern 2.2).
- **Shiv-home variants (pending decision)** — *Shiv · hero / inbox / launcher / dashboard* (`ShivHomeVariants.jsx`). Four full-page directions; **pick one to make canonical, then remove the rest.**

### 3.5 Channels — public (NIP-28)
- *Channels* (`ChannelList.jsx`) — joined channel list (# icon + name + about + unread Badge). No member counts, **no Discover tab**. Create / Join affordances.
- *Create channel* — icon + name + description; note that the first event id becomes the permanent channel id.
- *Join channel* (`JoinChannel.jsx`) — Scan QR **or** paste channel id **+ relay** (`wss://…`); found-preview → Join.
- *Channel chat* (`ChannelChat.jsx`) — **messages render as feed `NoteCard`s** (not bubbles) + the rich composer. No member count. See **Chat open position & unread** (§2.2) for how it opens and marks read.

### 3.6 Private channels (encrypted)
- *Create private* — encrypted note + name/description/icon.
- *Join private* (`JoinPrivateChannel.jsx`) — Scan QR **or** paste group id **+ relay**; "request goes to admin for approval".
- *Private detail* (`PrivateChannelDetail.jsx`) — **`NoteCard` feed** + composer (opens at the first unread; see §2.2 *Chat open position & unread*); lock + name (no member count); a requests badge in the header opens **pending requests as a bottom sheet** (Approve / Decline).

### 3.7 DMs & more
- *DM chat* (`DmChat.jsx`) — **`NoteCard` feed** + composer + an "end-to-end encrypted" pill. Opens at the first unread note with the "New notes" divider and a counted jump-to-latest button (§2.2 *Chat open position & unread*).
- *New message* (`CreateDm.jsx`) — search by name/npub + recent users.
- *Share sheet* (`ShareSheet.jsx`) — bottom sheet: **Quoting card on top** → the **rich composer** ("Add a note…", no send) → destinations (Feed / Channel / Private / DM) → "Share via…" → Share. Embed-by-value.
- *QR profile* (`QrProfile.jsx`) — segmented **My code** (avatar + npub + QR) / **Scan** (viewfinder → tapping it routes to *User profile*).
- *User profile* (`UserProfile.jsx`) — another person after scanning their QR / opening a user link: avatar, verified nip05, npub, about, **N notes · N following**, **Follow + Message**, then their recent notes.
- *Settings* / *Edit profile* — grouped settings (Account / AI / Storage / About) + profile editor (incl. read-only npub).

---

## 4. Key flow decisions (the "why")

1. **Brahma = graph + Manas, not a text editor.** The graph is the home; Manas lives in the side drawer; composing is a separate flow reached from the FAB.
2. **Every human chat is the feed note view.** DM / channel / private all render messages as flat `NoteCard`s (kinds 14/42/9023 are all Notes). Only **Shiv's AI chat** keeps `MessageBubble`s.
3. **The composer is the Shiv entry point.** Tapping the composer avatar (in any surface) → pick a Manas → chat grounded in that surface + Manas.
4. **Thread = references-on-top, flat replies, no nesting.**
5. **Single-accent everywhere, including the graph** (mono-blue circles).
6. **Onboarding speaks "Avatar"** (Create / Restore Your Avatar), not "identity/keys-as-identity".
7. **No fabricated data:** no channel member counts, no "Discover" feed.
8. **QR is first-class:** my-code + scan in the Vishnu header and the Spaces drawer; join-by-code screens (channel + private) offer QR + relay.
9. **Ganas: one dashboard, outcomes at a glance.** The Gana screen is a dashboard (totals → needs attention → each Gana → recent activity), not a list. Failure is surfaced with its reason and the Gana that caused it; success is a rate, and skips never count against it.
10. **A Gana's knowledge is an explicit, single choice:** No knowledge, Brahma, or one Manas. Brahma is the default; sending the whole library to a cloud model is warned about, never silent.

---

## 5. Mapping to the Flutter app

| Redesigned pattern/screen | Production widget / file |
|---|---|
| Theme tokens | `lib/core/theme/app_theme.dart` |
| NoteCard / ReferenceNoteCard / LargeNoteCard | `lib/common/widgets/note_card/*` |
| Rich composer + composer-chat | `lib/common/widgets/composer/uniun_composer.dart`, `lib/features/shiv/composer_chat/` |
| Thread layout | `lib/common/widgets/thread/message_thread_page.dart` + `thread_conversation_body.dart` |
| Brahma graph + Manas drawer | `lib/features/brahma/graph/*` (graphview), `lib/features/brahma/manas/widgets/brahma_drawer.dart` |
| Manas model | `lib/data/models/manas_model.dart`, `manas_note_link_model.dart` |
| Welcome (trimurti) | `lib/features/onboarding/pages/welcome_page.dart` |
| Gana form | `lib/features/shiv/gana/form/*` (knowledge chips in `widgets/gana_form_sections.dart`) |
| Gana dashboard | `lib/features/shiv/gana/dashboard/pages/gana_dashboard_page.dart`; widgets `gana_stat_tile.dart`, `gana_outcome_bar.dart`, `gana_dashboard_row.dart`, `gana_activity_tile.dart`, `gana_empty_state.dart` |
| Gana detail | `lib/features/shiv/gana/detail/pages/gana_detail_page.dart` |
| Floating nav | `lib/common/widgets/floating_nav.dart` |

Implementation rules from `CLAUDE.md` still bind: Clean Architecture (data/domain/presentation), `isar_community`, Freezed 3 `abstract class`, `@Injectable`, `Either<Failure,T>`, l10n for every string, no NIP-09 / no delete.

---

## 6. Open decisions

- [ ] **Shiv home** — choose one of *hero / inbox / launcher / dashboard* (or a hybrid) and make it canonical; remove the variants.
- [ ] Confirm the Vishnu header keeps the avatar (vs. wordmark) — currently menu · QR · avatar.
- [ ] Brahma Manas membership: multi-select (current) vs. single.

---

*Generated from the redesign gallery (`UNIUNDesignSystem/ui_kits/uniun_app/`). Update this doc as screens are finalized.*
